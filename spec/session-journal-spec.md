# Session Journal Specification

Version 2.0

## Purpose

A session journal is a small, committed record for coding agents and humans. After a fresh start it answers three
questions: what work is active, what evidence exists, and what should happen next.

## Required shape

Each piece of substantive work uses `sessions/YYYY-MM-DD-HHMM-<slug>.md`, or the repository's adapted journal
directory. The filename time is the session start in the machine-local timezone. Names without `HHMM` are still
recognised, so older journals keep working.

The header contains bold labels, not YAML:

```markdown
**Started:** YYYY-MM-DD HH:MM Zone
**Last updated:** YYYY-MM-DD HH:MM Zone
**Status:** ACTIVE | PAUSED | BLOCKED | DONE — one current-state line
**Worktree:** <name> (<branch>)              optional; only when written from a linked worktree
**Continues:** sessions/<earlier>.md         optional; links work that picks up an earlier journal
**Sessions:** <id8> (<worktree>/<branch>, <runtime>), ...   maintained by the hooks; do not edit
```

The body contains these sections, in order:

1. User intent
2. Live plan pointer
3. Milestones
4. Decisions and constraints
5. Verification evidence
6. Commits made
7. Files touched
8. Where we are now
9. Next step for a fresh agent
10. Open questions / loose ends
11. Change log

`Next step for a fresh agent` is mandatory and concrete. Name the next command, file, test, decision, or owner
action. It is shown to the next session, so write it for a reader who has seen nothing else. Section headings match
case-insensitively; the template's capitalization is the canonical form.

The journal directory also holds `README.md` and `TEMPLATE.md`. Neither is a journal.

## Modes

The first non-empty line under `## Live plan pointer` selects the mode:

- **THIN:** the line names a real artifact. The journal indexes outcomes and evidence and does not retell the
  artifact.
- **DETAILED:** the line is `none`, or the section is empty or missing. The journal is the canonical working record.

Promote recurring DETAILED work into a durable plan, specification, ADR, runbook, or tracker. Later journals then
point to it in THIN mode.

## Status

- **Open:** any status except the closed ones. `ACTIVE`, `PAUSED`, `BLOCKED`, `WAITING` and `IN PROGRESS` are all
  open. A journal without a status line is neither open nor a candidate.
- **Closed:** `DONE`, `COMPLETE`, `COMPLETED`, `DELIVERED`, `CLOSED`, `SUPERSEDED`, and `ABANDONED`. A closed journal
  is background. It is never offered as a candidate.

A session that ends while its journal is still `ACTIVE` sets it to `PAUSED`, unless no session was bound to the
journal or another live session owns it. Ending with `/clear` records the session but leaves the status alone,
because the same window usually carries on.

## Binding: which journal is this session's

A journal belongs to the sessions that write it. Picking "the newest journal" is not a selection rule; it is the
defect this version removes. With parallel sessions, the newest journal is usually someone else's.

1. Each agent session has a lease: its journal, worktree, branch, role, and liveness. The lease is local state and
   is never committed.
2. The session's first write to a journal binds the lease to that journal. Writes count when they come through the
   editing tools, through `apply_patch`, or through a recognisable shell write: a redirect, `tee`, `sed -i`, a
   copy or move target, or a Python or Node write call. A shell command that changes a journal some other way is
   detected by modification time afterwards. A command that changes more than two journals binds nothing.
3. Resume and compaction keep the session id, so the binding survives them. `/clear` and a fork start a new session:
   - after `/clear`, the new session is offered the window's previous journal first;
   - a fork is told that the journal in its history belongs to the original session.
4. A session with no binding is shown **candidates**: up to five open journals, ranked by
   - a matching `Worktree:` (or `Sessions:`) line,
   - uncommitted changes to the journal itself,
   - an `ACTIVE` or `IN PROGRESS` status,
   - the most recent write by an agent session; file modification time is used only when no agent wrote it.

   On the first prompt, up to two more journals whose name or title match the prompt are added.
5. A journal bound to another **live** session is **IN USE**. A session is live while its heartbeat is under 45
   minutes old, or while its agent process is still running (capped at 24 hours). Writes into an IN USE journal
   are denied. The agent starts its own journal with `**Continues:**` instead. When two sessions are bound to the
   same journal, the earlier binder owns it.
6. Journals live in the **main checkout**. A session in a linked worktree writes to the main checkout's directory
   and adds a `**Worktree:**` line. A write into a linked worktree's copy of the directory is denied.
7. Hooks anchor on the session's project, never on the directory an agent has `cd`-ed into. A project without a
   journal directory is left untouched: the hooks never create it.

## When to update

Journal only when something lands: a commit, a meaningful edit, a dispatch, a verified result, or a decision. A turn
that only read or answered changes nothing in the journal.

The Stop hook nudges at most once per turn. It nudges only when the turn landed work and did not touch the
session's own journal, and one of these holds:

- a commit or push landed;
- the session has no journal yet;
- this is the second landed turn in a row without an update;
- 20 or more minutes have passed since the session's last journal update.

A turn that only read and answered is never nudged. The THIN nudge is one line naming the plan pointer. The DETAILED
nudge asks for milestones, evidence, and the next step.

When a journal grows past 40 KB, start a new journal with `**Continues:**` rather than growing it further.

## Roles

- **Lead** (default): owns journals.
- **Worker** (`JOURNAL_ROLE=worker`): writes no journal; its report to the lead is the record. Its journal writes
  are denied.
- **Soft worker:** a session whose first prompt matches a configured dispatch pattern. It is never nudged, but may
  keep a journal when its task asks for one.

When a worker's turn lands work, the hooks add one line to a local ledger. The lead is shown each line once, on its
next prompt, and records the outcome in its own journal.

## Evidence

Record evidence a reader can re-run: the command, the test name, the CI run, the artifact reference. A count
captured at write time ("38 of 38 passing") becomes false as soon as the suite grows, and the next agent will
believe it and repeat it.

## Safety and signal

Include only concise outcomes, decisions, verification evidence, commit references, issue IDs, and artifact
pointers. Never include:

- secrets or credential fragments;
- customer or personal data;
- large logs;
- duplicated plan prose;
- unverified claims.

Redact a credential to a key name, an env-var reference, or an explicit placeholder. A redaction must not itself read
as a credential, so conforming redactions pass the check. By default, a journal write whose new text looks like a
credential is denied. The denial names the line and the rule, never the value. A line that a human has verified may
carry `<!-- journal-secrets-ok -->`.
