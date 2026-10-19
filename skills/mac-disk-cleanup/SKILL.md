---
name: mac-disk-cleanup
description: Reclaim disk space on this Mac by verifying and removing done agent session copies (T3/Claude/Codex worktrees, transcripts, caches).
---

# Mac Disk Cleanup

You clean a Mac filled with leftover agent session copies. The mechanical work
lives in the companion script from
https://github.com/Ravilochan/mac_cleanup (expected at
`~/mac-cleanup/cleanup.sh`, or `mac-cleanup` on PATH); you add judgment for
the cases it conservatively keeps. Full background in that repo's README.

## Procedure

1. **Baseline.** Record `df -h /` and list live agent processes (`ps aux`
   and match for t3, claude, codex). Never stop, restart, or otherwise
   disturb user processes.
2. **Inventory (dry run).** Run `mac-cleanup` (preview only, deletes
   nothing). Read every `KEEP (reason)` line — each names work the script
   refused to delete.
3. **Triage keepers.** For each keeper, confirm the reason with git:
   - `git status --porcelain` (must be empty to delete),
   - `git rev-list --count HEAD --not --remotes` (must be 0, meaning
     everything pushed; nonzero is local-only work — keep and warn loudly),
   - `git merge-base --is-ancestor HEAD <mainline>` per repo mainline
     (`develop`, `dev`, or `main`) for manual checkouts,
   - `git cherry <mainline> HEAD` for suspicious cases (`-` means already
     upstream under other SHAs, `+` means genuinely unique — keep),
   - `gh pr list --head <branch> --state all` for unmerged branches (an
     open PR means the work continues; remote branches are never deleted).
   - Never delete: main checkouts (dirs owning their own `.git/`),
     uncommitted changes, unpushed commits, anything a live process
     references, or anything fresh.
4. **Execute.** Run `mac-cleanup --execute`. Add `--purge-kept` only to
   strip regenerables (`node_modules`, `dist`, `coverage`, `.venv`) inside
   kept session copies whose git work must stay. Never run `mo purge`
   globally (it strips live projects).
5. **Verify + report.** Re-run the dry run to confirm keepers, record
   `df -h /`, and report: freed space, deleted counts, keepers with
   reasons, and any unpushed/uncommitted work found (branch plus location —
   the user must push it).

## Scope notes

- Candidate copies: `~/.t3/worktrees/*/*`, `~/.codex/worktrees/*`,
  `<projects>/*/.claude/worktrees/*`, linked top-level duplicates, `/tmp`
  review sandboxes registered in git, orphan transcripts, old logs.
- Caches handled by the script: `mo clean` (non-interactive),
  `pnpm store prune`, Docker dangling/builder data only when the daemon
  runs. Codex leftovers only when Codex is not installed.

## Installing this skill

- Muse: `muse skills install <path-to-this-folder>`
- Claude Code: copy this folder to `~/.claude/skills/mac-disk-cleanup/`
- Codex: copy this folder to `~/.codex/skills/mac-disk-cleanup/`
