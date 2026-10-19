# mac-disk-cleanup

Reclaim disk space on a Mac crowded with **leftover AI-agent session copies**:
T3/Codex worktrees, Claude session worktrees, duplicate checkouts, orphan
transcripts, and stale caches. Dry-run by default; every deletion is verified
first (clean tree, everything pushed, no live process, stale).

Born from a real cleanup that took a MacBook from **1.5 GB free (90% full) to
~45 GB free** — see [docs/EXAMPLE-RUN.md](docs/EXAMPLE-RUN.md) for the full
story and numbers.

## Install

```sh
git clone https://github.com/Ravilochan/mac_cleanup.git ~/mac-cleanup
ln -s ~/mac-cleanup/cleanup.sh ~/.local/bin/mac-cleanup  # if ~/.local/bin is on PATH
```

Optional: install the companion agent skill (adds judgment for ambiguous
cases) — [skills/mac-disk-cleanup/SKILL.md](skills/mac-disk-cleanup/SKILL.md).
The file follows the cross-agent skill format and also works in Claude Code
(`~/.claude/skills/`) and Codex (`~/.codex/skills/`).

Requirements: macOS, bash, git, and optionally
[`mo` (mole)](https://mole.fit), `pnpm`, `docker`, `gh`.

## Usage

```sh
mac-cleanup              # preview only — deletes nothing (the default)
mac-cleanup --execute    # actually delete, after reviewing the preview
mac-cleanup --execute --stale-hours 24   # idle threshold (default: 48)
mac-cleanup --execute --purge-kept       # also strip node_modules/dist/.venv
                                         # inside KEPT session copies
```

Every run logs to `~/mac-cleanup/logs/` and prints `KEEP (reason)` lines that
tell you exactly what still holds unique work.

To scan project roots outside auto-discovery:

```sh
CLEANUP_PROJECT_ROOTS="$HOME/work $HOME/personal" mac-cleanup --execute
```

## What it cleans

1. Session worktrees: `~/.t3/worktrees/*/*`, `~/.codex/worktrees/*`,
   `<projects>/*/.claude/worktrees/*`
2. Linked duplicate checkouts (top-level dirs whose `.git` is a file) —
   only when fully merged
3. `/tmp` review sandboxes registered as git worktrees
4. Transcripts for worktrees that no longer exist, Muse sessions older than
   14 days, T3 logs older than 7 days
5. Orphaned Codex app data (only when Codex is not installed)
6. Caches: `mo clean` (non-interactive), `pnpm store prune`, Docker
   dangling/builder data (daemon must be running)

## Safety model

A worktree copy is deleted only when **all** hold:

- **Clean** — `git status --porcelain` is empty
- **Pushed** — every commit reachable from HEAD exists on origin
  (`git rev-list --count HEAD --not --remotes` is 0)
- **Idle** — no live process references the path
- **Stale** — untouched for the threshold (root + git admin dir)
- **Merged** (manual top-level checkouts only) — ancestor of a mainline
  (`develop` / `dev` / `main`)

Never touched: main checkouts, uncommitted/unpushed work, live or fresh
copies, remote or local branches, live `node_modules` (`mo purge` is never
run globally), Docker volumes/images in use.

## License

MIT — see [LICENSE](LICENSE).
