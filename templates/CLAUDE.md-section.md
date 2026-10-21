## Session-journal discipline

For substantive work, keep one journal in `{{SESSIONS_DIR}}/` using `YYYY-MM-DD-HHMM-<slug>.md`, started from `{{SESSIONS_DIR}}/TEMPLATE.md`. The SessionStart hook names the journal this session is bound to, or lists candidates: continue the one the task really continues, never one marked IN USE (start your own with `**Continues:**` instead), and never pick a journal by newest name or date. Search older work with `python3 .claude/hooks/session-journal.py find <words>`.

Journal only when something lands: a commit, a meaningful edit, a dispatch, a verified result, or a decision. Use THIN mode when `## Live plan pointer` names a governing artifact, and DETAILED mode when it is `none`. When you update, refresh `**Last updated:**`, `**Status:**`, evidence, current state, and `## Next step for a fresh agent`. Never put secrets or credential fragments in a journal. Workers started with `JOURNAL_ROLE=worker` report to their lead and write no journal. Follow `{{SESSIONS_DIR}}/README.md` and the `session-journal` skill.

If both CLAUDE.md and AGENTS.md carry this block, keep their session-journal rules synchronized.
