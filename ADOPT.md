# Agent Adoption Contract

You are installing the Session Journal discipline into a target repository. Adapt it to the repository you actually
find, preserve existing configuration, and prove the result before finishing.

**Read `skills/session-journal/SKILL.md` first and follow it.** The skill holds the judgment calls:

- where journals live;
- how to adapt the setup to this repository's agents and orchestration;
- lead and worker roles;
- migrating old journals;
- what may never go in a journal.

This contract adds the order of work, the question budget, and the proof you must report.

Ask at most three questions, and only when discovery cannot answer them:

1. Which journal directory should be used, if root `sessions/` and `docs/sessions/` are equally plausible?
2. Should journals be committed (the default) or ignored locally?
3. Should the optional spine-promotion nudge be installed?

## Phase A — survey without writing

Inspect the following and record what you find for your final report:

1. **Agent runtimes.** Check `.claude/settings.json`, `.codex/hooks.json`, `.codex/config.toml`, and
   instruction-only runtimes. Treat user-level configuration as a clue, never as permission to modify global
   files.
2. **Instruction files.** Check for CLAUDE.md, AGENTS.md, both, or neither. Inventory existing hooks and plan a
   merge; never replace a hooks array.
3. **Documentation.** Look for plans, specifications, ADRs, runbooks, or an issue tracker. Use the strongest active
   artifact as the default THIN pointer. If the repository has no documentation habit, default to DETAILED and
   `none`.
4. **Journal location.** Follow skill §1.
   - A monorepo gets one journal directory at its root.
   - A repository whose developers use linked worktrees still gets one directory: the hooks resolve it in the main
     checkout.
5. **Existing journals or notes.** If the repository already has v1 journals or session notes elsewhere, plan the
   migration in skill §6.
6. **Multi-agent setup.** If an orchestrator dispatches worker agents, find how a worker can be recognised: an
   environment variable the orchestrator can set, or the shape of the dispatch prompt. Skill §2 and §4 turn that
   into `JOURNAL_ROLE=worker` or `JOURNAL_WORKER_PROMPT`.
7. **Timezone.** Run `date +%Z` in the target repository and use that local label.
8. **Ignore rules.** Journals are meant to be committed. Warn if a rule ignores the chosen directory or `.claude/`.
   Ask Question 2 only if the intent stays unclear.
9. **Repository root.** The installer refuses a subdirectory of a git repository. Target the root.
10. **Python.** Confirm `python3 --version` reports 3.8 or later wherever agents run.

Before writing anything, ask Question 3, unless the user's request already says whether to install the optional
spine-promotion module.

## Phase B — install and adapt

1. Clone or download this repository to a temporary location. Then run `./install.sh <target>` with the discovered
   `--sessions-dir`, `--plan-pointer`, `--codex`, and/or `--no-claude` flags. Do not rebuild its merge logic by hand.
   If the installer cannot run, perform the equivalent steps manually from `hooks/*.snippet.json`, and explain why
   in the report.
2. Adapt `<sessions>/README.md` (the THIN default, the `date +%Z` result, the evidence vocabulary) and, if needed,
   `TEMPLATE.md`. Adapt the sentinel blocks in CLAUDE.md and AGENTS.md. Keep the twin-sync sentence only when both
   files exist. A re-run of the installer preserves all of these.
3. Add any environment prefixes from skill §2 to the generated hook commands. A re-run preserves them.
4. If Question 3 opted into spine promotion, merge `extras/spine-promotion/journal-spine-promotion-nudge.sh` as an
   extra Stop handler and test it. It is managed by hand, and you must also remove it by hand.

Never delete or rewrite an existing user hook. Never commit unless the user asked or repository conventions already
authorize it. Never put a real or realistic credential in a demonstration journal. If a settings file contains
comments or JSON5, do not normalize it: show the matching snippet and ask the user to merge it.

## Phase C — verify before finishing

Run `./doctor.sh <target>` and include its output. It must exit 0, apart from "the installation is committed",
which Phase D resolves.

Then exercise the hook directly. Pipe JSON into `python3 .claude/hooks/session-journal.py hook <Event>` from the
target root, using a throwaway `SESSION_JOURNAL_STATE_DIR`. For the cases that need landed work, also write a
two-line Claude Code transcript, and pass its path as `transcript_path`.

| Check | Expected proof |
| --- | --- |
| Empty start | With no journal, SessionStart returns context that names `TEMPLATE.md` |
| Candidates | A synthetic ACTIVE journal is listed with its next step; a DONE one is not |
| Binding | A PostToolUse `Write` to a journal binds it: `whoami <sid>` shows it |
| IN USE | A PreToolUse `Write` from a second session id into that journal is denied |
| Read-only turn | Stop with no edits in the transcript prints `{}` |
| Landed turn | Stop after an edit and a commit, with no journal write, returns `decision: block` once; a second Stop in the same turn does not |
| Credential | A PreToolUse `Write` whose content holds a credential assignment built at runtime is denied, and the reason does not contain the value |
| Redaction | The same write with `<redacted>` is allowed |

Delete the fixtures and the throwaway state. Then write the first real journal, about this adoption session, with
no secrets.

For Codex, trust the project, review the hooks with `/hooks`, and run one short task with the installed Codex
version. For Claude Code, run a short headless task if available. If a runtime cannot be exercised, say so. Never
claim that an unobserved hook fired.

## Phase D — hand it to the team

1. Commit `.claude/` (and `.codex/` and `.agents/` when Codex is wired), the instruction blocks, and the journal
   directory together. `.claude/state/` ignores itself.
2. Confirm that no ignore rule excludes them. The doctor checks this.
3. Tell the user what a teammate must do on first clone (normally nothing). Tell them that `./doctor.sh` is how
   anyone checks the setup later.
4. Mention `python3 .claude/hooks/session-journal.py skip` and `SESSION_JOURNAL_SKIP=1`. Mention
   `JOURNAL_ROLE=worker` for dispatched agents.

## Phase E — document reversal

`./install.sh <repo> --uninstall`, with the runtime flags you installed with, removes:

- the owned hook groups (v1 and v2), the script, and the skills;
- local state;
- the instruction blocks.

It keeps the journal directory, its README, and TEMPLATE.md, because they are project history. Upgrading is the
same command as installing, run from a fresh clone.

## Final report

Report:

- the survey decisions;
- the changed files;
- the `./doctor.sh` output and the behavioural matrix;
- any runtime limitation;
- the role configuration;
- the first journal's path;
- whether the install was committed;
- the uninstall command;
- any question that used the three-question budget.
