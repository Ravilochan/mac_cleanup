#!/bin/bash
# mac-cleanup — re-runnable disk cleanup for agent-worktree-heavy Macs.
#
# What it removes (all verified first, see checks below):
#   1. Stale agent session worktrees: ~/.t3/worktrees/*/*,
#      <project>/*/.claude/worktrees/*, ~/.codex/worktrees/*
#   2. Linked duplicate checkouts (top-level dirs whose .git is a file, i.e.
#      a gitlink into another local repo) — only when fully merged.
#   3. /tmp review sandboxes registered as git worktrees.
#   4. Transcripts/sessions for worktrees that no longer exist (orphans),
#      Muse session logs older than 14 days, T3 logs older than 7 days.
#   5. Orphaned Codex app leftovers (only when Codex is not installed).
#   6. Caches via `pnpm store prune`, `mo clean`, Docker dangling/builder
#      data (only when the Docker daemon is running).
#
# What it NEVER touches: main checkouts (dirs owning their own .git/),
# unpushed or uncommitted work, anything referenced by a live process,
# fresh (< STALE_HOURS) work, remote branches, live project node_modules
# (`mo purge` is deliberately NOT run globally).
#
# Usage:
#   cleanup.sh                 preview only (dry run, default)
#   cleanup.sh --execute       actually delete
#   cleanup.sh --execute --stale-hours 24
#   cleanup.sh --execute --purge-kept   also strip regenerables
#                              (node_modules/dist/coverage/.venv) inside
#                              kept session copies (git work is preserved)
#
#   CLEANUP_PROJECT_ROOTS="..." overrides the auto-discovered project roots.
set -u
DRY_RUN=1
STALE_HOURS=48
PURGE_KEPT=0
T3_WT="$HOME/.t3/worktrees"
CODEX_WT="$HOME/.codex/worktrees"
# Project roots to scan (space-separated). Override with e.g.:
#   CLEANUP_PROJECT_ROOTS="$HOME/work $HOME/personal" mac-cleanup --execute
# Default: auto-discover top-level home dirs containing git repos.
if [ -n "${CLEANUP_PROJECT_ROOTS:-}" ]; then PROJECT_ROOTS="$CLEANUP_PROJECT_ROOTS";
else
  PROJECT_ROOTS=""
  for _rd in "$HOME"/*/; do
    case "$_rd" in "$HOME/Library/"*) continue;; esac
    ls -d "$_rd"*/.git >/dev/null 2>&1 && PROJECT_ROOTS="$PROJECT_ROOTS ${_rd%/}"
  done
fi
SRC="$0"
while [ -L "$SRC" ]; do D="$(dirname "$SRC")"; SRC="$(readlink "$SRC")"; case "$SRC" in /*) ;; *) SRC="$D/$SRC";; esac; done
SCRIPT_DIR="$(cd "$(dirname "$SRC")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
DELETED=0; KEPT=0; FAILED=0; PURGED=0

usage() { sed -n '2,28p' "$0"; exit 0; }
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) DRY_RUN=0 ;;
    --stale-hours) STALE_HOURS="$2"; shift ;;
    --purge-kept) PURGE_KEPT=1 ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $1"; usage ;;
  esac
  shift
done
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
say()  { echo "$@" | tee -a "$LOG"; }
skip() { KEPT=$((KEPT+1)); say "KEEP  $1 ($2)"; }

shopt -s nullglob
df_line() { df -h / | tail -n 1; }

# ---- per-worktree checks (all must pass for deletion) ----
is_clean()  { [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]; }
is_pushed() { # every commit reachable from HEAD must exist on some remote
  [ "$(git -C "$1" rev-list --count HEAD --not --remotes 2>/dev/null)" = "0" ]
}
is_idle()   { # no live process command line references this path
  ! ps aux 2>/dev/null | grep -F -- "$1" | grep -v "grep -F --" | grep -q .
}
is_stale()  { # worktree root AND its git admin dir untouched for STALE_HOURS
  local d="$1" min=$((STALE_HOURS*60)) g
  find "$d" -maxdepth 0 -mmin +"$min" 2>/dev/null | grep -q . || return 1
  g="$(git -C "$d" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  ! find "$g" -mmin -"$min" -print -quit 2>/dev/null | grep -q .
}
is_merged() { # HEAD is an ancestor of some mainline branch
  local d="$1" ref
  for ref in $(git -C "$d" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null) \
             refs/remotes/origin/develop refs/remotes/origin/dev \
             refs/remotes/origin/main refs/remotes/origin/master; do
    git -C "$d" merge-base --is-ancestor HEAD "$ref" 2>/dev/null && return 0
  done
  return 1
}
existing_wt_dirs() { # prints all live session-copy worktree dirs, no trailing slash
  local d root
  for d in "$T3_WT"/*/*/ "$CODEX_WT"/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
  for root in $PROJECT_ROOTS; do
    [ -d "$root" ] || continue
    for d in "$root"/*/.claude/worktrees/*/; do [ -d "$d" ] && printf '%s\n' "${d%/}"; done
  done
}
encode_path() { printf '%s' "$1" | tr '/.' '-'; } # transcript encoding: / and . become -
transcript_alive() { # $1 = transcript dir basename; true if its path is a live worktree or inside one
  local wt enc
  while IFS= read -r wt; do
    [ -n "$wt" ] || continue
    enc="$(encode_path "$wt")"
    [ "$1" = "$enc" ] && return 0
    case "$1" in "$enc"-*) return 0;; esac
  done < <(existing_wt_dirs)
  return 1
}
main_repo_of() { # toplevel of the repo owning this (possibly linked) worktree
  local common; common="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  git --git-dir="$common" rev-parse --show-toplevel 2>/dev/null
}
remove_wt() { # $1 = worktree path (uses owning repo for registry cleanup)
  local wt="$1" top
  top="$(main_repo_of "$wt")" || { say "FAIL  $wt (no owning repo)"; FAILED=$((FAILED+1)); return; }
  if [ "$DRY_RUN" = 1 ]; then say "DEL   $wt ($(du -sh "$wt" 2>/dev/null | cut -f1))"; DELETED=$((DELETED+1)); return; fi
  if git -C "$top" worktree remove --force "$wt" >>"$LOG" 2>&1; then
    say "DEL   $wt"; DELETED=$((DELETED+1))
  else say "FAIL  $wt (worktree remove failed)"; FAILED=$((FAILED+1)); fi
}
purge_regenerables() { # strip rebuildable dirs, keep all git-tracked/unique work
  local d="$1"
  if [ "$DRY_RUN" = 1 ]; then say "PRUNE $d (regenerables only)"; PURGED=$((PURGED+1)); return; fi
  find "$d" -maxdepth 4 \( -name node_modules -o -name dist -o -name coverage \
    -o -name .venv -o -name .pytest_cache -o -name .ruff_cache \) \
    -prune -exec rm -rf {} + 2>/dev/null
  say "PRUNE $d -> $(du -sh "$d" 2>/dev/null | cut -f1) left"; PURGED=$((PURGED+1))
}
# $1 = worktree, $2 = 1 if top-level manual checkout (requires merged too)
consider_wt() {
  local wt="$1" strict="$2" why=""
  wt="${wt%/}"
  if [ -z "$(ls -A "$wt" 2>/dev/null)" ]; then # empty dir: nothing to lose
    if is_idle "$wt" && find "$wt" -maxdepth 0 -mmin +"$((STALE_HOURS*60))" 2>/dev/null | grep -q .; then
      if [ "$DRY_RUN" = 1 ]; then say "DEL   $wt (empty dir)"; DELETED=$((DELETED+1));
      elif rmdir "$wt" 2>/dev/null; then say "DEL   $wt (empty dir)"; DELETED=$((DELETED+1));
      else skip "$wt" "rmdir failed"; fi
    else skip "$wt" "empty dir, fresh or busy"; fi
    return
  fi
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { skip "$wt" "not a git worktree"; return; }
  is_clean "$wt"  || why="uncommitted changes"
  [ -z "$why" ] && { is_pushed "$wt" || why="local-only commits (not on origin)"; }
  [ -z "$why" ] && { is_idle "$wt"   || why="referenced by a live process"; }
  [ -z "$why" ] && { is_stale "$wt"  || why="active within ${STALE_HOURS}h"; }
  [ -z "$why" ] && [ "$strict" = 1 ] && { is_merged "$wt" || why="branch not merged (kept: manual checkout)"; }
  if [ -n "$why" ]; then
    skip "$wt" "$why"
    if [ "$PURGE_KEPT" = 1 ] && [ "$strict" = 0 ] && { [ "$why" = "uncommitted changes" ] || [ "$why" = "local-only commits (not on origin)" ]; }; then
      is_idle "$wt" && is_stale "$wt" && purge_regenerables "$wt"
    fi
    return
  fi
  remove_wt "$wt"
}

say "=== mac-cleanup $(date) (dry-run=$DRY_RUN stale-hours=$STALE_HOURS) ==="
say "disk before: $(df_line)"
say "project roots:$PROJECT_ROOTS"
MAIN_REPOS=""
for root in $PROJECT_ROOTS; do
  [ -d "$root" ] || continue
  for d in "$root"/*/; do
    [ -d "$d/.git" ] || continue # main checkouts only (own .git dir)
    MAIN_REPOS="$MAIN_REPOS $d"
    git -C "$d" fetch --prune origin --quiet >>"$LOG" 2>&1 \
      || say "note: fetch failed in $d (offline? using cached refs)"
  done
done
say "--- session-copy worktrees ---"
for d in "$T3_WT"/*/*/ "$CODEX_WT"/*/; do [ -d "$d" ] && consider_wt "$d" 0; done
for root in $PROJECT_ROOTS; do
  [ -d "$root" ] || continue
  for d in "$root"/*/.claude/worktrees/*/; do [ -d "$d" ] && consider_wt "$d" 0; done
done
say "--- top-level linked duplicates (merged only) ---"
for root in $PROJECT_ROOTS; do
  [ -d "$root" ] || continue
  for d in "$root"/*/; do
    [ -f "$d/.git" ] && consider_wt "$d" 1 # .git is a file => linked copy
  done
done
say "--- /tmp worktrees registered in git ---"
TMP_WTS=""
for repo in $MAIN_REPOS; do
  TMP_WTS="$TMP_WTS$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^worktree ' | cut -d' ' -f2-)
"
done
while IFS= read -r wt; do
  [ -n "$wt" ] || continue
  case "$wt" in /tmp/*|/private/tmp/*) consider_wt "$wt" 0 ;; esac
done <<< "$TMP_WTS"
if [ "$DRY_RUN" = 0 ]; then
  for repo in $MAIN_REPOS; do git -C "$repo" worktree prune >>"$LOG" 2>&1; done
  say "pruned stale worktree registry entries"
fi
rm_path() { # $1 = path, $2 = label
  [ -e "$1" ] || return 0
  if [ "$DRY_RUN" = 1 ]; then say "DEL   $2: $1 ($(du -sh "$1" 2>/dev/null | cut -f1))"; DELETED=$((DELETED+1)); return; fi
  rm -rf "$1" && { say "DEL   $2: $1"; DELETED=$((DELETED+1)); } \
               || { say "FAIL  $1"; FAILED=$((FAILED+1)); }
}
say "--- orphaned session transcripts ---"
for tdir in "$HOME/.claude_work/projects" "$HOME/.claude/projects"; do
  [ -d "$tdir" ] || continue
  for e in "$tdir"/*t3-worktrees* "$tdir"/*claude-worktrees*; do
    [ -d "$e" ] || continue
    id="${e##*-}" # trailing slug for the live-process guard
    if transcript_alive "$(basename "$e")" \
       || ps aux 2>/dev/null | grep -F -- "$id" | grep -v "grep -F --" | grep -q .; then
      skip "$e" "worktree still exists or session live"
    else rm_path "$e" "orphan transcript"; fi
  done
  for e in "$tdir"/*t3code-claude-title*; do # single-use tmp title sessions
    [ -d "$e" ] || continue
    if find "$e" -maxdepth 0 -mmin +1440 2>/dev/null | grep -q .; then rm_path "$e" "title-tmp"; else skip "$e" "fresh title session"; fi
  done
done
say "--- Muse sessions older than 14 days (never today) ---"
CUTOFF="$(date -v-14d +%Y/%m/%d 2>/dev/null || echo none)"
if [ "$CUTOFF" != "none" ]; then
  for y in "$HOME"/.local/share/muse/sessions/2[0-9][0-9][0-9]/; do
    for m in "$y"[0-1][0-9]/; do for dd in "$m"[0-3][0-9]/; do
      rel="${y: -5:4}/${m: -3:2}/${dd: -3:2}"
      [ -d "$dd" ] || continue
      if [[ "$rel" < "$CUTOFF" ]]; then rm_path "${dd%/}" "old muse session"; fi
    done; done
  done
fi
say "--- T3 logs older than 7 days ---"
if [ -d "$HOME/.t3/userdata/logs" ]; then
  while IFS= read -r f; do rm_path "$f" "old T3 log"; done < <(find "$HOME/.t3/userdata/logs" -type f -mtime +7 2>/dev/null)
fi
say "--- Codex leftovers (only if Codex not installed) ---"
if [ ! -d /Applications/Codex.app ] && [ ! -d "$HOME/Applications/Codex.app" ] \
   && ! command -v codex >/dev/null 2>&1 \
   && ! ps aux 2>/dev/null | grep -i "[c]odex.app" | grep -q .; then
  for p in "$HOME/.codex/plugins" "$HOME/.codex/.tmp" "$HOME/.codex/cache" \
           "$HOME/.codex/computer-use" "$HOME/.codex/vendor_imports" \
           "$HOME/.codex/logs_2.sqlite" "$HOME/.codex/logs_2.sqlite-shm" "$HOME/.codex/logs_2.sqlite-wal" \
           "$HOME/Library/Application Support/Codex" "$HOME/Library/Application Support/com.openai.codex" \
           "$HOME/Library/Application Support/OpenAI/Codex" "$HOME/Library/Caches/Codex" \
           "$HOME/Library/Caches/com.openai.codex" "$HOME/Library/Logs/com.openai.codex" \
           "$HOME/Documents/Codex"; do rm_path "$p" "codex leftover"; done
else say "Codex appears installed/running — skipped"; fi
say "--- package caches ---"
if command -v pnpm >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then say "would run: pnpm store prune"; else pnpm store prune 2>&1 | tail -n 2 | tee -a "$LOG"; fi
else say "pnpm not found — skipped"; fi
say "--- Docker (dangling + builder only, never volumes/images in use) ---"
if docker info >/dev/null 2>&1; then
  docker system df 2>&1 | tee -a "$LOG" | head -n 8
  if [ "$DRY_RUN" = 1 ]; then say "would run: docker system prune -f + builder prune -f";
  else docker system prune -f >>"$LOG" 2>&1; docker builder prune -f >>"$LOG" 2>&1; say "docker pruned (dangling + builder)"; fi
else say "Docker daemon not running — skipped"; fi
say "--- mole clean ---"
if command -v mo >/dev/null 2>&1; then
  if [ "$DRY_RUN" = 1 ]; then say "would run: mo clean";
  else mo clean < /dev/null 2>&1 | tail -n 4 | tee -a "$LOG"; fi
else say "mole (mo) not found — skipped"; fi
say "=== done: deleted=$DELETED pruned=$PURGED kept=$KEPT failed=$FAILED ==="
say "disk after:  $(df_line)"
say "log: $LOG"
[ "$FAILED" = 0 ] || exit 1
