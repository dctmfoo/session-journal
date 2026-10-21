# Changelog

All notable changes to this project are recorded here. Versions follow
[semantic versioning](https://semver.org/): the public surface is the journal
shape, the hook contract, the installer flags, and the environment variables.

## 2.0.0

Session-bound journals. 1.x asked "which journal is newest?" at every session start and every turn end. With more
than one agent session in a repository (parallel chats, worktrees, a lead dispatching workers), the newest journal
is usually someone else's. 2.0 asks "which journal is *this* session's?" instead.

The changes follow a field audit of a long-running private deployment of this discipline: about a thousand
sessions, and several hundred journals. Its generic findings, in the order they drove the design:

- **The start pointer named the wrong journal.** In the busiest period, the newest-journal pointer was irrelevant to
  the prompt in roughly half of all sessions, and agents opened it less every month.
- **Parallel sessions polluted each other.** A fresher journal from another session silenced this session's nudge,
  or redirected it. About one in eight reminders named another session's journal. Agents appended unrelated work
  into journals that other live sessions were writing.
- **Size followed writer count.** Journals with one writer stayed small. Journals with many writers grew past
  tens of kilobytes and mixed workstreams.
- **Nudges arrived where they did not belong.** They fired on read-only turns, looped on long coordinator sessions,
  and reached dispatched workers that correctly had no journal. A leaked loop marker silenced the turn after every
  nudge.
- **Linked worktrees** wrote journals into their own stale copy of the journal directory.
- **Shell and Python journal writes** were invisible to a check based on editing tools.
- **A background job** that touched a journal took over the pointer.

### Behaviour changes (why this is a major version)

- **One Python 3 script replaces both shell hooks.** It handles six events (`SessionStart`, `UserPromptSubmit`,
  `PreToolUse`, `PostToolUse`, `Stop`, `SessionEnd`) and a CLI. It uses the standard library only and needs
  Python 3.8 or later. `jq` is still needed by the installer only.
- **SessionStart no longer injects the newest journal.** It names the journal this session is bound to. With no
  binding, it lists up to five ranked open candidates, with IN USE marked. On the first prompt it adds up to two
  journals whose name or title matches.
- **Stop checks this session's own journal, from this turn's facts.** It no longer compares file modification
  times. It nudges at most once per turn, and only when the turn landed work. Freshness windows are gone.
- **Writes into a journal another live session owns are denied.** So are writes into a linked worktree's copy of
  the journal directory.
- **The credential check moved from Stop to PreToolUse.** The write is denied before it reaches disk, and no Stop
  loop is needed. The rules are retuned for compound key names (`dbPassword=`, `SERVICE_API_KEY:`), prose, table
  cells, URL credentials, and CLI flags. The bare-hexadecimal rule is gone.
- **Sessions end by marking an ACTIVE journal PAUSED**, and record themselves on a `**Sessions:**` line. `PAUSED`
  joins the status vocabulary. `JOURNAL_PAUSE_ON_END=0` turns this off.
- **`SESSION_JOURNAL_DIR` is relative to the main checkout.** The installer rewrites the v1 absolute form.

### Removed

- `hooks/session-journal-pointer.sh` and `hooks/session-journal-nudge.sh`. The installer removes them, and their hook
  groups, from adopted repositories.
- `JOURNAL_FRESH_SECS`, `JOURNAL_REQUIRE_CONTENT_CHANGE`, and `JOURNAL_STOP_MARKER_TTL_SECS`. A re-install drops
  them from the generated commands.

### Added

- Session leases in `.claude/state/session-journal/`, which ignores itself.
- Main-checkout resolution for linked worktrees. A pooled worktree whose directory is named after the repository is
  labelled by its branch.
- `/clear` handling: the window's previous journal is offered first. A fork never inherits its parent's journal.
- Roles. `JOURNAL_ROLE=worker` sessions are never nudged and their journal writes are denied. `JOURNAL_WORKER_PROMPT`
  makes soft workers from a configurable first-prompt pattern. A worker ledger shows landed worker results to the
  lead once.
- A size limit (`JOURNAL_MAX_KB`, default 40) that tells the agent to continue in a new journal with
  `**Continues:**`.
- The CLI: `candidates`, `find`, `reconstruct`, `list`, `health`, `scan`, `sweep [--by-git]`, `whoami`, `bound`,
  `bind`, `release`, `role`, `skip`, and `version`.
- Codex support for every event. `apply_patch` edits are read from `tool_input.command`, Codex turns are keyed by
  `turn_id`, and a Stop hook always prints JSON, as Codex requires.
- The `session-journal` agent skill (`skills/session-journal/`), with a Codex mirror that carries
  `agents/openai.yaml` (`codex/skills/session-journal/`). The installer places them in `.claude/skills/` and
  `.agents/skills/`. `ADOPT.md` now routes the adopting agent through the skill.
- `--no-skill`. The doctor now checks all six events, the `|| true` safety net on each command, leftover v1 hooks,
  Python, and that local state stays out of git. It also runs the real hooks against a scratch state directory.
- `tests/test_journal.py`: scenario tests for parallel sessions, IN USE, worktrees, `/clear`, forks, workers,
  debouncing, THIN nudges, credentials, Codex-shaped input, sweep, and a custom journal directory.

### Upgrade notes

Re-run `./install.sh <repo>` from a fresh clone, with the flags you installed with, then run `./doctor.sh <repo>`
and commit. Journals are not renamed or rewritten. The adapted README, TEMPLATE, and instruction blocks are kept.
Pass `--refresh-docs` to pick up the 2.0 wording for them, which describes candidates and IN USE.

## 1.1.0

The first release that treats the discipline as something people *operate*
rather than something people install. Every fix below is a defect that only
appears on the second of something: the second journal, the second session, the
second install, the second teammate.

### Upgrade notes

Re-run `./install.sh <repo>` from a fresh clone. The rerun is now
non-destructive — it preserves your adapted `sessions/README.md`, your
instruction block, and any environment overrides on the generated commands, and
prints a line for each thing it kept. Use `--refresh-docs` to deliberately
regenerate them.

After upgrading, run `./doctor.sh <repo>` and commit the result of the install.

Two behaviour changes are worth knowing about before you upgrade:

- A journal whose `**Status:**` is `DONE` is no longer presented as the live
  frontier. If you relied on a DONE journal's next step being injected, mark the
  journal `ACTIVE` instead.
- Freshness now requires the journal's *content* to have changed when other
  files changed, not just its timestamp. Set
  `JOURNAL_REQUIRE_CONTENT_CHANGE=0` to restore the old mtime-only behaviour.

### Fixed

- **The newest journal is now actually the newest.** Selection was decided by
  mtime alone, so any operation that gives several journals the same timestamp —
  a fresh `git clone`, a branch checkout, an unpacked archive — tied the
  comparison and kept the alphabetically *oldest* journal. A teammate cloning
  the repository was handed the wrong journal. mtime still leads; the filename
  now settles ties.
- **A finished session is no longer replayed as the live frontier.** The pointer
  injected a `DONE` journal's next step verbatim, so a fresh agent could be told
  "No repository work remains" as its entire first minute. The pointer now
  prefers the newest `ACTIVE` or `BLOCKED` journal and, when every journal is
  closed, says so.
- **The secrets guard no longer blocks its own prescribed remediation.**
  `password: <redacted>` and `token: stored-in-ci-secrets` both exited 2, and
  because the guard runs ahead of the `stop_hook_active` bail, the runtime could
  not break the resulting block → redact → block loop. Values are now inspected
  rather than merely detected.
- **Digest context matches whole words.** `Avoid`, `Android` and `paranoid` all
  satisfied the `oid` exemption and silently disabled hex-secret detection for
  neighbouring lines.
- **The Stop hook reads all of stdin.** Pretty-printed hook JSON used to defeat
  the `stop_hook_active` check and suppress the marker fallback at the same
  time, leaving no loop protection at all.
- **The one-shot marker expires.** It outlived the session that armed it and
  silently swallowed the next session's first nudge.
- **A bare `touch` no longer satisfies the freshness gate** when tracked files
  changed and the journal did not. Untracked scratch files are ignored, and a
  journal committed alongside its work counts as recorded, so the gate does not
  punish the workflow this project teaches.
- **The installer refuses before it acts.** An unmatched sentinel used to
  produce "refusing to modify it" *after* both hooks were copied and merged
  live, leaving enforcement wired up with no instruction block, plus a stray
  `.tmp` file in the repository.
- **Re-running the installer preserves your adaptations.** It previously deleted
  the `JOURNAL_FRESH_SECS` override, the adapted sessions README, and any local
  edit inside the instruction block — all three of which `ADOPT.md` instructs
  the adopting agent to write. A rerun without `--sessions-dir` also keeps the
  journal directory already configured, instead of reverting to the default and
  leaving every existing journal unreachable.
- **The journal template is installed.** Both the pointer hook and the generated
  README told agents to start from a local template that nothing ever placed, so
  first journals were written from memory. This was the root cause of heading
  drift.
- **Next-step headings match case-insensitively**, so a title-cased heading no
  longer silently voids the injected payload.
- **Installing into a subdirectory of a git repository is refused** instead of
  succeeding and then failing silently forever.
- **A journal directory that symlinks outside the repository is refused.**
- Neither hook creates the sessions directory any more; they are read paths.
- The optional spine-promotion hook no longer hands raw `awk` diagnostics to the
  agent as a Stop block when the journal is unreadable.
- A non-numeric `JOURNAL_FRESH_SECS` warns and falls back to 300 instead of
  leaking a shell error and blocking.

### Added

- `doctor.sh` — a re-runnable self-check. `ADOPT.md` Phase C was a matrix the
  installing agent ran once and nobody could run again, yet every failure mode
  here is silent. The doctor also checks what adoption never did: whether the
  installation is committed, whether a teammate will actually receive it,
  whether the registered command still resolves, and which journal the pointer
  would deliver right now.
- `SESSION_JOURNAL_SKIP=1` — a documented escape for sessions that genuinely
  need no journal. The secrets guard still runs.
- `JOURNAL_REQUIRE_CONTENT_CHANGE` and `JOURNAL_STOP_MARKER_TTL_SECS`.
- `--plan-pointer` so a deterministic install can produce THIN mode instead of
  always contradicting `ADOPT.md`.
- `--refresh-docs` to deliberately regenerate what a rerun now preserves.
- A `VERSION` file, stamped into the installed hook scripts, so an adopted
  repository can tell what it has.
- `SECURITY.md`.

### Changed

- The journal template asks for evidence a reader can re-run — a command, a
  test, a CI URL — rather than a count frozen at write time. This project's own
  verification record had drifted for exactly that reason.
- CI pins its actions by commit SHA, asserts on macOS that the interpreter the
  hooks' shebang selects really is bash 3.2, runs the secrets guard over *every*
  tracked journal rather than only the newest, and checks that the
  documentation's own claims still match the code.

## 1.0.0

Initial public release: the journal specification, THIN and DETAILED modes, the
`SessionStart` pointer, the `Stop` freshness nudge and secrets guard, the
`ADOPT.md` adoption contract, the deterministic installer, and the optional
spine-promotion module.
