# Session: fix the defects that only appear when the discipline is operated, not installed

**Started:** 2026-08-27 01:30 IST
**Last updated:** 2026-08-27 03:30 IST
**Status:** ACTIVE — adversarial re-review found six regressions in the fixes themselves; all are corrected and retested, branch is green at 121 checks

## User intent

Compare this project against `stephenschoettler/hermes-lcm` — a ~64k-line Python
"Lossless Context Management" plugin solving the same problem at the opposite
weight — look for ways to improve session-journal, then "fix everything".

## Live plan pointer
none

## Milestones

- 2026-08-27 01:35 — Cloned hermes-lcm and surveyed both repos. Ground truth: hermes-lcm is 63,730 lines of Python over 242 commits; session-journal is 924 lines of shell and markdown over 10 commits.
- 2026-08-27 01:52 — Reproduced the headline defect before delegating: in a fresh `git clone`, the pointer hook injected the alphabetically *oldest* journal, because every file lands in the same second and bash 3.2 compares `-nt` at whole-second resolution.
- 2026-08-27 02:12 — Six-agent exploration finished (four lenses, synthesis, adversarial review). Its most valuable output was a refutation: the obvious "sort by filename" fix would have broken journals appended to across days, which the spec explicitly allows.
- 2026-08-27 02:20 — Twelve defects confirmed by direct reproduction, not by agent assertion.
- 2026-08-27 02:35 — Hooks fixed: selection, DONE handling, heading tolerance, secrets guard, stdin drain, marker TTL, content-change freshness. Suite 41 → 70.
- 2026-08-27 02:45 — Installer made safe to run twice and safe to fail; `doctor.sh` added. Suite 70 → 89.
- 2026-08-27 02:54 — Docs, spec 1.1, CHANGELOG, SECURITY.md, and CI hardening. Suite 89 → 95.
- 2026-08-27 03:20 — Adversarial re-review of the branch. It earned its keep: the secrets guard I "fixed" had in fact stopped catching `PASSWORD="..."`, backticked, and punctuated values, and a plain installer re-run silently relocated the journal directory, orphaning real journals.
- 2026-08-27 03:30 — All six confirmed regressions corrected, each with a regression test. Suite 95 → 121.

## Decisions and constraints

- **Borrow ideas from hermes-lcm, never mechanisms.** Its database, summary DAG, embeddings, retrieval tools, and rollups all answer problems this project deliberately does not have: there is no transcript to store, because the journal *is* the compression. Four ideas transferred at markdown-and-shell weight: occurrence time is not observation time, current is not last-finalized, redaction must be idempotent by construction, and prose belongs under test.
- **Selection is mtime-first with filename as tie-break, not filename-first.** `spec:36` allows appending to one journal across days, so an older filename can legitimately be the live journal. Filename-first would have regressed that while fixing the clone case.
- **The secrets guard inspects values, not just key names.** It was blocking `password: <redacted>` — the exact remediation its own message prescribes — ahead of the `stop_hook_active` bail, so the runtime could not break the loop. Only a placeholder shape may exempt a value: decoration is stripped first, so a quoted or backticked credential is still caught.
- **Freshness must measure work, not timestamps.** A bare `touch` satisfied the old gate with zero characters changed. Where git can tell, the journal must have actually moved. `JOURNAL_REQUIRE_CONTENT_CHANGE=0` restores the old behaviour for workflows this annoys.
- **No Claude-only plugin distribution.** It would install per-machine outside git, breaking both Codex parity and the git-reviewable, team-shared premise.

## Verification evidence

Prefer re-running these over trusting the numbers:

- `bats tests` — 121 checks, currently all passing. `tests/docs.bats` fails deliberately if this count drifts from `grep -c '^@test' tests/*.bats`.
- `shellcheck hooks/*.sh extras/spine-promotion/*.sh install.sh doctor.sh` — clean.
- `./doctor.sh .` — passes against this repository's own installation.
- Fresh-clone selection: clone a repo with journals dated January, May and August; the pointer must name the August journal. Was naming January.
- DONE handling: `./hooks/session-journal-pointer.sh` in this repo used to emit "No repository work remains" as a fresh agent's whole first minute.
- Redaction acceptance: `password: <redacted>`, `token: stored-in-ci-secrets`, `api_key: $STRIPE_API_KEY` must all exit 0; `api_key: sk-live-...` must still exit 2.
- Digest context: a line containing "Avoid" or "Android" must no longer suppress hex detection on its neighbours, while a real `SHA-256:` receipt still survives.
- Installer refusal: an unmatched sentinel must leave no `.claude/`, no `sessions/README.md`, and no `.tmp` file.

## Commits made

- `0deb916` fix: operate on the journal the agent actually needs, and stop the Stop-hook loops
- `a9e4e2a` fix: make installation safe to run twice and safe to fail, and add a doctor
- `afb51d6` docs: state the selection rule, hold the prose under test, and dogfood the discipline
- `5fc948c` docs: teach ADOPT.md the doctor, the template, and the handoff to a team
- `2a1ddcd` fix: repair the regressions an adversarial review found in the 1.1.0 fixes

## Files touched

- `hooks/session-journal-pointer.sh` — selection rule, DONE handling, case-insensitive headings, no mkdir on a read path
- `hooks/session-journal-nudge.sh` — value-aware secrets guard, whole-word digest context, full stdin drain, marker TTL, content-change freshness, `SESSION_JOURNAL_SKIP`
- `extras/spine-promotion/journal-spine-promotion-nudge.sh` — same selection rule; fails open on an unreadable journal
- `install.sh` — preflight before any write, non-destructive rerun, ships `TEMPLATE.md`, `--plan-pointer`, `--refresh-docs`, version stamping
- `doctor.sh` — new; re-runnable self-check
- `spec/session-journal-spec.md` — 1.1: selection is now specified, not left to the implementation
- `templates/`, `README.md`, `CHANGELOG.md`, `SECURITY.md`, `docs/verification.md`, `.github/workflows/ci.yml`, `tests/`

## Where we are now

All twelve original defects are fixed, and so are the six regressions the
adversarial review found in those fixes. Both rounds have regression tests; the
suite went 41 → 121. The project now dogfoods itself: `.claude/` is installed
here, so CI's `./doctor.sh .` step is a real check rather than a formality.

The two changes flagged as riskiest before the review were exactly the two that
were wrong, in opposite directions. The secrets guard had traded away real
coverage — it stopped catching quoted, backticked and punctuated values, which
is how credentials are actually written — and the freshness gate had the wrong
premise, treating "the working tree is dirty" as "the journal did not move", so
committing the journal alongside the work turned the gate hostile.

## Next step for a fresh agent

The branch is green and ready for a maintainer read. Before merging, decide the
two open questions below. After merging, tag `1.1.0` and change the README's
`degit` instruction to name the tag, since it currently points strangers at a
moving `main`.

## Open questions / loose ends

- The freshness gate can only assert what git can prove: the journal is dirty, or it rode along in the most recent commit. A journal that did neither while tracked work accumulated gets nudged. That is defensible but it is a heuristic, and `JOURNAL_REQUIRE_CONTENT_CHANGE=0` is the escape if it proves noisy in real use.
- The secrets guard now exempts values under 8 characters and values whose first word says where the secret lives. Both exemptions exist to keep the prescribed redaction from re-triggering the block; both are documented in SECURITY.md as known misses. Worth revisiting if a real miss shows up.
- Commit `0016aa6` changed hook behaviour in this repository with no journal written, which means the Stop hook was either bypassed or not firing here. The hooks are installed now, so the next such commit will answer it.
- `1.1.0` is not tagged yet.

## Change log

- 2026-08-27 01:30 — journal created
- 2026-08-27 02:54 — recorded hook, installer, doctor, docs, and CI work
- 2026-08-27 03:30 — recorded the adversarial review and the six regressions it caught
