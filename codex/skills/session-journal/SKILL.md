---
name: session-journal
description: Adopt, adapt, and operate session-bound journals for coding agents. Use when installing session-journal into a project, when adapting it to a project's layout, agents, or multi-agent setup, when migrating or backfilling old journals, when choosing which journal to read, continue, or create, when a session-journal hook message (candidates, IN USE, SESSION-JOURNAL nudge, worker) needs acting on, or when recalling a topic from earlier sessions ("when did we discuss X", "find the session where").
---

# Session journal

A journal is one markdown file per piece of work, written for the next agent. Hooks bind each journal to the
session that writes it. Scripts handle what can be checked mechanically: binding, IN USE locks, candidates, nudges,
the secrets check, and the doctor. This skill covers the judgment calls they cannot make.

The upstream source is `https://github.com/dctmfoo/session-journal`. In it, `ADOPT.md` is the full adoption
contract and `spec/session-journal-spec.md` is the journal format.

## 1. Adopt it in a project

1. Survey before you write anything:
   - Runtimes: `.claude/settings.json`, `.codex/hooks.json` or `.codex/config.toml`, and instruction-only agents.
   - Instruction files: `CLAUDE.md` and `AGENTS.md`.
   - Documentation: plans, specs, ADRs, trackers.
   - Ignore rules: is `.claude/` ignored? Is the journal directory ignored?
   - Repository shape: a single repo, a monorepo, or a repo where people use worktrees.
2. Pick the journal directory. Use root `sessions/` by default. Use `docs/sessions/` when the project keeps
   process docs under `docs/`. A monorepo gets one directory at its root: a journal follows the session, not the
   package. Do not put journals in another repository or in a linked worktree.
3. Run the installer from a clone of the upstream repository. Do not hand-merge hooks:
   `./install.sh <repo> [--sessions-dir docs/sessions] [--plan-pointer <plan path>] [--codex] [--no-claude]`.
   It refuses rather than clobbering existing configuration. It is safe to run twice. It replaces v1 shell hooks.
4. Adapt what the installer generated:
   - `<sessions>/README.md`: the default plan pointer, the `date +%Z` zone label, and the project's evidence
     vocabulary (test names, ticket ids, CI URLs).
   - `TEMPLATE.md`: add header lines only if the project needs them (one `**<repo> branch:**` line per repository
     the work touches, for example).
   - The sentinel blocks in `CLAUDE.md` and `AGENTS.md`: keep both in sync when both exist.
5. Verify with `./doctor.sh <repo>`. Report what it printed; never claim a hook fired unless you observed it.
6. Commit `.claude/` (and `.codex/`, `.agents/`), the instruction blocks, and the journal directory together.
   Until then only your machine has the discipline. `.claude/state/` stays local: it ignores itself.

## 2. Adapt it to how the project works

Configure behaviour with environment prefixes on the generated hook commands. A re-run of the installer keeps them.

| Situation | Setting |
| --- | --- |
| Journals somewhere other than `sessions/` | `--sessions-dir` (written as `SESSION_JOURNAL_DIR`) |
| An orchestrator sends workers a recognisable first prompt | `JOURNAL_WORKER_PROMPT='<regex>'`: those sessions are soft workers and are never nudged |
| Dispatching or deploying from the shell counts as landing work | `JOURNAL_LANDING_BASH='<regex>'` (git commit and push already count) |
| A private repository where the owner wants credentials recorded | `JOURNAL_SECRETS=warn`, only with the owner's explicit decision |
| Sessions should not mark a journal PAUSED when they end | `JOURNAL_PAUSE_ON_END=0` |
| Different lock or nudge timing | `JOURNAL_LIVE_MIN`, `JOURNAL_NUDGE_MIN`, `JOURNAL_MAX_KB` |

Anything the hooks cannot know, such as the evidence vocabulary or which documents govern which work, goes in
`<sessions>/README.md`.

## 3. Operate it every session

1. **At start**, read what the SessionStart hook printed:
   - **Bound** (after resume or compact): re-read that journal and continue it.
   - **Candidates**: after the user's first message, decide whether the task really continues one of them.
     - If it does, read the journal and append to it.
     - If the journal you need is marked IN USE, create your own journal with
       `**Continues:** <sessions>/<old>.md`.
     - Otherwise create a new journal from `TEMPLATE.md`. The filename uses the session-start time in local
       time: `YYYY-MM-DD-HHMM-<slug>.md`.
   - **Never** pick a journal by newest name or mtime (`ls | tail`). For related work, use
     `python3 .claude/hooks/session-journal.py candidates <words>` or `find <words>`.
2. **Journal only when something lands**: a commit, an edit that matters, a dispatch, a verified result, or a
   decision. A turn that only read or answered changes nothing in the journal. When the Stop hook asks for an
   update on a read-only turn, ignore it. One update per landed turn is enough.
3. **THIN or DETAILED.** When a plan, spec, or tracker governs the work, put its path under
   `## Live plan pointer` (THIN). Milestones are then one line each and point into that document; do not retell
   it. Use `none` (DETAILED) only when no such document exists; the journal is then the record.
4. **Keep `## Next step for a fresh agent` standalone.** It is shown verbatim to the next session. Name the
   command, file, or decision.
5. **Close it.** When the work is finished, set `**Status:** DONE`. When it is unfinished, set
   `**Status:** PAUSED`. Before `/clear`, bring `Where we are now` and `Next step` up to date.
6. **Split, don't bloat.** One live writer per journal. When a journal passes about 40 KB, or starts covering a
   second workstream, start a new journal that says `**Continues:**`.

## 4. Lead and worker roles

- A **lead** (the default) owns a journal. It records what it dispatched, and later the outcome, one line each.
- A **worker** never writes journals. Its report to the lead is the record.
  - Start workers with `JOURNAL_ROLE=worker`. That makes them hard workers: their journal writes are denied.
  - A worker whose task explicitly asks for a deliverable journal is started without that variable, or runs
    `python3 .claude/hooks/session-journal.py role lead`.
- When a worker's turn lands work, the hooks add a line to a local ledger. The lead sees that line on its next
  prompt. Record the outcome in the lead's journal then.
- Linked worktrees still write journals in the main checkout's directory. Give a new journal a
  `**Worktree:** <name> (<branch>)` header line; the SessionStart hook prints the exact line to use.

## 5. Never in a journal

- Credentials or fragments of them: passwords, keys, tokens, connection strings, private keys. Write where the
  secret lives instead: a vault entry name, an env var such as `$API_TOKEN`, or `<redacted>`. The PreToolUse hook
  denies credential-shaped writes. Mark a line with `<!-- journal-secrets-ok -->` only after a human has checked
  that it holds no credential.
- Customer data, personal data, internal hostnames that must not leave the project, and large logs.
- Verbatim transcripts, duplicated plan text, and unverified claims stated as fact.

## 6. Migrate or backfill old journals

1. Run `./install.sh <repo>` once. It replaces the v1 pointer and nudge hooks and keeps every journal, README,
   and template.
2. Do not rename existing journals. Names without HHMM still work.
3. Optional, with the owner's agreement:
   - `python3 .claude/hooks/session-journal.py sweep 168 --by-git --dry-run` lists stale `ACTIVE` journals.
     Rerun it without `--dry-run` to mark them `PAUSED`.
   - A journal that lacks `## Next step for a fresh agent` or a `**Status:**` line gets those added by hand,
     from its own content. Do not invent history.
4. Journals kept in another place, such as `docs/notes/`: move them with `git mv` into the journal directory under
   the dated name, and say so in a commit message. Do not copy them.
5. Run `./doctor.sh <repo>` and `python3 .claude/hooks/session-journal.py scan`, then commit.

## 7. Recall a topic from earlier sessions

Search in this order, and do not report "never discussed" until all three tiers have run:

1. **Journals**: `python3 .claude/hooks/session-journal.py find <word> [word...]`. Try 3 to 6 variants of the
   user's words: synonyms, component names, ticket ids.
2. **Governing documents**: grep the plans and specs that THIN journals point to. Map a document hit back to
   journals with `grep -l '<doc path>' <sessions>/*.md`.
3. **Transcripts**: only when tiers 1 and 2 come up thin. Use `reconstruct <journal>` for the sessions that
   wrote a journal, or grep the agent's transcript store. Label those hits "discussion only, nothing landed".

Answer in three parts:

- 2 to 5 sentences of thread history.
- A table of hits (date, journal, state, governing document).
- The newest relevant `Next step for a fresh agent`, as the point to continue from.
