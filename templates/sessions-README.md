# Session journals

This repository keeps one markdown journal per substantive working session in `{{SESSIONS_DIR}}/`. Journals are written for the next agent: they preserve continuity without replaying a conversation.

## Local defaults

- Default governing-plan pointer: `{{DEFAULT_PLAN_POINTER}}`
- Timestamp label: `{{TIMEZONE}}`
- Useful evidence vocabulary: {{EVIDENCE_VOCABULARY}}
- Journals are committed unless the repository's maintainers explicitly choose local-only journals.

## Filename

Use `YYYY-MM-DD-HHMM-<short-kebab-intent>.md` with the session-start time.

## THIN and DETAILED modes

- **THIN:** `## Live plan pointer` names a governing plan, specification, tracker, ADR, or runbook. Record one-line outcomes and evidence pointers; never duplicate the governing document.
- **DETAILED:** the pointer is `none`. The journal is the canonical record for a one-off investigation or small task. If the topic recurs, promote it to a durable document and switch the journal to THIN.

## Lifecycle

- Same work continuing across days: append to the same journal and update its header.
- Unrelated work: create a new journal.
- After context compaction: read the newest journal and its live plan before acting, then refresh the journal if the compaction changed the next step.
- Keep `**Status:**` to one line; move state history to `## Change log`.
- Put updates in their proper sections, not at the end of the file.

## Content contract

Allowed: concise milestones, decisions, verification evidence, commit references, issue IDs, and artifact pointers.

Never include credentials, credential fragments, private tokens, large logs, duplicated plan prose, or speculation presented as fact. The Stop hook scans the newest journal for common secret shapes. A false-positive line may carry `<!-- journal-secrets-ok -->` only after a human verifies that the line contains no credential value.

Start from the repository's installed journal template or from `templates/session-journal.md` in the upstream project.
