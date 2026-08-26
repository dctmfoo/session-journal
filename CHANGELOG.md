# Changelog

All notable changes to this project are recorded here. Versions follow
[semantic versioning](https://semver.org/): the public surface is the journal
shape, the hook contract, the installer flags, and the environment variables.

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
- **A bare `touch` no longer satisfies the freshness gate** when other files in
  the repository changed and the journal did not.
- **The installer refuses before it acts.** An unmatched sentinel used to
  produce "refusing to modify it" *after* both hooks were copied and merged
  live, leaving enforcement wired up with no instruction block, plus a stray
  `.tmp` file in the repository.
- **Re-running the installer preserves your adaptations.** It previously deleted
  the `JOURNAL_FRESH_SECS` override, the adapted sessions README, and any local
  edit inside the instruction block — all three of which `ADOPT.md` instructs
  the adopting agent to write.
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
- CI pins its actions by commit SHA, runs the suite under `bash 3.2` as well as
  the system bash, runs the secrets guard over *every* tracked journal rather
  than only the newest, and checks that the documentation's own claims still
  match the code.

## 1.0.0

Initial public release: the journal specification, THIN and DETAILED modes, the
`SessionStart` pointer, the `Stop` freshness nudge and secrets guard, the
`ADOPT.md` adoption contract, the deterministic installer, and the optional
spine-promotion module.
