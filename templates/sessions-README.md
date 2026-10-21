# Session journals

This repository keeps one markdown journal per piece of substantive work in `{{SESSIONS_DIR}}/`. Journals are written for the next agent: they preserve continuity without replaying a conversation.

## Local defaults

- Default governing-plan pointer: `{{DEFAULT_PLAN_POINTER}}`
- Timestamp label: `{{TIMEZONE}}`
- Useful evidence vocabulary: {{EVIDENCE_VOCABULARY}}
- Journals are committed unless the repository's maintainers explicitly choose local-only journals.

## Filename

Use `YYYY-MM-DD-HHMM-<short-kebab-intent>.md` with the session-start time. Start from `{{SESSIONS_DIR}}/TEMPLATE.md`.

## Which journal

Hooks bind each journal to the session that writes it (`.claude/hooks/session-journal.py`, state in `.claude/state/session-journal/`, which never leaves this machine).

- At start, the hook names the journal this session is bound to, or lists up to five open candidates ranked by worktree, uncommitted edits, status, and recent agent writes.
- After the first prompt, continue the candidate the task really continues, or create a new journal. Your first write binds it.
- A journal marked **IN USE** belongs to another live session: writes into it are denied. Start your own journal with `**Continues:** {{SESSIONS_DIR}}/<old>.md`.
- Never pick a journal by newest name or date. Use `python3 .claude/hooks/session-journal.py candidates <words>` or `find <words>`; `reconstruct <journal>` shows the sessions that wrote one.
- Sessions in a linked worktree still write here, in the main checkout, and add `**Worktree:** <name> (<branch>)`.

## THIN and DETAILED modes

- **THIN:** `## Live plan pointer` names a governing plan, specification, tracker, ADR, or runbook. Record one-line outcomes and evidence pointers; never duplicate the governing document.
- **DETAILED:** the pointer is `none`. The journal is the canonical record for a one-off investigation or small task. If the topic recurs, promote it to a durable document and switch the journal to THIN.

## Lifecycle

- Journal only when something lands: a commit, a meaningful edit, a dispatch, a verified result, or a decision. A turn that only read or answered changes nothing here, and the Stop hook does not ask for it.
- Same work continuing across days: append to the same journal and update its header.
- Unrelated work, or a journal past about 40 KB: create a new journal; link it with `**Continues:**`.
- After context compaction: read the bound journal and its live plan before acting.
- Keep `**Status:**` to one line; move state history to `## Change log`.
- Set `**Status:** DONE` when the work is finished. A session that ends with the journal still `ACTIVE` marks it `PAUSED`; the `**Sessions:**` line is maintained by the hook. If the journal was committed and unchanged, the hook leaves the file alone and writes those lines later, with the next change to it or on `sweep`.
- Workers started with `JOURNAL_ROLE=worker` never write journals; their lead records the outcome.

## Sessions that need no journal

A typo fix, a dependency bump, or a question answered without changing anything does not need a journal. Start the agent with `SESSION_JOURNAL_SKIP=1`, or run `python3 .claude/hooks/session-journal.py skip`, instead of writing a journal about nothing.

## Content contract

Allowed: concise milestones, decisions, verification evidence, commit references, issue IDs, and artifact pointers.

Prefer evidence that can be re-run over a number captured at write time: name the command, the test, or the CI run.

Never include credentials, credential fragments, private tokens, customer or personal data, large logs, duplicated plan prose, or speculation presented as fact. The PreToolUse hook denies a journal write that looks like it carries a credential and names only the line and rule, never the value. Redact to a key name, an env-var reference, or `<redacted>`. A remaining false positive may carry `<!-- journal-secrets-ok -->` only after a human verifies that the line contains no credential value.
