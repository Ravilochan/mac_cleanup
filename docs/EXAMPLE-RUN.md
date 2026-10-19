# Example run — 2026-10-20 (author's MacBook)

The session this tool was born from. Disk started at **1.5 GB free (90%
full)** and ended at **~45 GB free** — about **43 GB reclaimed** in total.

## Where the space was

| Location | Was | Outcome |
|---|---|---|
| `~/.t3/worktrees/*/*` — 22 T3 session worktrees | 9.3 GB | 21 deleted, 1 live + 1 purged kept |
| `~/CSW/*/.claude/worktrees/*` — 67 Claude session worktrees | ~26 GB | 59 deleted, 8 kept |
| `~/CSW/docman-e2e-root` — merged duplicate checkout | 52 MB | deleted |
| `/private/tmp` PR-review sandboxes (8 dirs) | 1.2 GB | deleted |
| Session transcripts for deleted worktrees (`.claude*`, Muse) | ~1.4 GB | deleted (orphans + >14 days old) |
| T3 logs older than 7 days | 69 MB | deleted |
| Orphaned Codex app data (app not installed) | ~810 MB | deleted, 27 MB user data kept |
| pnpm/npm/pip caches via `mo clean` | ~1.9 GB | cleaned |
| pnpm store (2.5 GB) | all referenced by live projects | kept — nothing reclaimable |
| Docker `Docker.raw` | 228 GB sparse, ~197 MB real | kept — daemon stopped, nothing to gain |

89 worktree/sandbox copies removed with zero failures; every keeper was
re-verified after deletion.

## How "work is done" was decided

Each candidate had to pass every check before deletion:

1. **Clean** — `git status --porcelain` empty. Regenerable-only dirt
   (`coverage/`) was judged case by case.
2. **Pushed** — `git rev-list --count HEAD --not --remotes` is 0. Three
   small agent worktrees failed this (fixes never pushed) and were kept.
3. **Idle** — no live process command line references the path. One T3
   worktree was in active use and was kept.
4. **Stale** — worktree root and git admin dir untouched for 48+ hours.
5. **Merged (manual checkouts only)** — top-level duplicates additionally
   had to be merged into a mainline. Checkouts with open PRs were kept.

Special investigations from the first pass:

- **Squash-merge detection**: `git cherry origin/<mainline> HEAD` (`-` =
  already upstream under other SHAs, `+` = genuinely unique → keep).
  Mainlines differ per repo (`develop` vs `dev` vs `main`).
- **PR state**: `gh pr list --head <branch> --state all`. Open PR means the
  work continues — remote branches are never deleted, only verified local
  copies.
- **Remote refresh**: read-only `git fetch --prune origin` in each main
  repo first, so `[gone]` (deleted-after-merge) signals are current.
- **Removal method**: linked worktrees via `git worktree remove --force`
  from the owning repo (registry stays clean, local branches preserved).

## Kept on purpose (warnings carried forward)

- One **live** T3 worktree with an active session.
- Three manual checkouts with **open PRs**.
- **Unpushed work existing only on disk**: an unpushed bug fix, two sets of
  PR-review fixes in agent worktrees, unique commits in two dashboard
  worktrees, uncommitted deploy/health-check changes, and untracked audit
  tests — all kept, four of them *purged* instead (regenerables stripped,
  unique work preserved).
- `.codex` sessions/memories/auth, October Muse sessions, the T3 database,
  all main checkouts, all remote branches.
