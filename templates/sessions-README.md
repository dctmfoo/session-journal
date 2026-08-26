# Session journals

This repository keeps one markdown journal per substantive working session in `{{SESSIONS_DIR}}/`. Journals are written for the next agent: they preserve continuity without replaying a conversation.

## Local defaults

- Default governing-plan pointer: `{{DEFAULT_PLAN_POINTER}}`
- Timestamp label: `{{TIMEZONE}}`
- Useful evidence vocabulary: {{EVIDENCE_VOCABULARY}}
- Journals are committed unless the repository's maintainers explicitly choose local-only journals.

## Filename

Use `YYYY-MM-DD-HHMM-<short-kebab-intent>.md` with the session-start time. Start from `{{SESSIONS_DIR}}/TEMPLATE.md`.

## THIN and DETAILED modes

- **THIN:** `## Live plan pointer` names a governing plan, specification, tracker, ADR, or runbook. Record one-line outcomes and evidence pointers; never duplicate the governing document.
- **DETAILED:** the pointer is `none`. The journal is the canonical record for a one-off investigation or small task. If the topic recurs, promote it to a durable document and switch the journal to THIN.

## Lifecycle

- Same work continuing across days: append to the same journal and update its header.
- Unrelated work: create a new journal.
- After context compaction: read the newest journal and its live plan before acting, then refresh the journal if the compaction changed the next step.
- Keep `**Status:**` to one line; move state history to `## Change log`.
- Put updates in their proper sections, not at the end of the file.
- Set `**Status:** DONE` when the work is finished. A DONE journal is treated as background, not as the live frontier, so the next session starts clean instead of inheriting a finished next step.

## Sessions that need no journal

A typo fix, a dependency bump, or a question answered without changing anything does not need a journal. Set `SESSION_JOURNAL_SKIP=1` for that session instead of writing a journal about nothing or working around the Stop hook. The secrets guard still runs.

## Content contract

Allowed: concise milestones, decisions, verification evidence, commit references, issue IDs, and artifact pointers.

Prefer evidence that can be re-run over a number captured at write time. `bats tests — 41 checks, see CI run <url>` can be checked by the next reader; `38 of 38 pass` becomes false the moment the suite grows, and the next agent will believe it and repeat it.

Never include credentials, credential fragments, private tokens, large logs, duplicated plan prose, or speculation presented as fact. The Stop hook scans the newest journal for common secret shapes. Redact a value to a key name, an env-var reference, or a placeholder such as `<redacted>`. A remaining false positive may carry `<!-- journal-secrets-ok -->` only after a human verifies that the line contains no credential value.
