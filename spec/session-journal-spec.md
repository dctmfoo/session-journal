# Session Journal Specification

Version 1.1

## Purpose

A session journal is a small, committed continuity record for coding agents and humans. It answers three questions after a fresh start: what work is active, what evidence exists, and what should happen next.

## Required shape

Each substantive session uses `sessions/YYYY-MM-DD-HHMM-<slug>.md`, or the repository's adapted journal directory. The filename time is the session start in the machine-local timezone.

The header contains bold labels, not YAML:

```markdown
**Started:** YYYY-MM-DD HH:MM Zone
**Last updated:** YYYY-MM-DD HH:MM Zone
**Status:** ACTIVE | DONE | BLOCKED — one current-state line
```

The body contains, in order: User intent; Live plan pointer; Milestones; Decisions and constraints; Verification evidence; Commits made; Files touched; Where we are now; Next step for a fresh agent; Open questions / loose ends; Change log.

`Next step for a fresh agent` is mandatory and concrete. Name the next command, file, test, decision, or owner action. It is injected verbatim at the start of the next session, so write it for a reader who has seen nothing else. Section headings are matched case-insensitively, but the template's capitalization is the canonical form.

Journal directories also carry two non-journal files, `README.md` and `TEMPLATE.md`. Neither is a journal and neither is ever selected as one.

## Modes

The first non-empty line under `## Live plan pointer` selects the mode:

- A real artifact path means **THIN**. The journal indexes outcomes and evidence without retelling the artifact.
- `none`, an empty section, or a missing section means **DETAILED**. The journal is the canonical working record.

Recurring DETAILED work should be promoted into a durable plan, specification, ADR, runbook, or tracker; future journals then point to it in THIN mode.

## Lifecycle

Create a journal once intent is clear. Continue the same work in the same file even across days. Start unrelated work in a new file. After manual or automatic context compaction, reread the newest journal and governing artifact before taking action.

Update `Last updated`, the one-line status, evidence, current state, next step, and change log before the end of every resumable turn. A Stop hook may treat a journal older than five minutes as stale; repositories can configure that window.

Not every session earns a journal. A typo fix, a dependency bump, or a question answered without changing anything should be skipped explicitly rather than recorded as a journal about nothing.

## Selecting the live journal

The live journal is the one a fresh agent must read first. Selecting it is a defined operation, not an implementation detail:

1. Consider every `*.md` in the journal directory except `README.md` and `TEMPLATE.md`.
2. Prefer the most recently modified. Modification time reflects the working session, which is why a journal appended to across days stays live even though its filename is older.
3. Break ties by filename, descending. Ties are common and not exotic: a fresh clone, a branch checkout, an unpacked archive, or a restored backup gives every journal the same timestamp, and the filename carries the session-start time precisely so it can settle them.
4. `DONE` marks a finished session, not the live frontier. If the journal selected above is `DONE`, prefer instead the most recent journal whose status is `ACTIVE` or `BLOCKED`. If none exists, report that the newest journal is closed rather than presenting its next step as live work.

## Evidence

Record evidence a reader can re-run: the command, the test name, the CI run, the artifact reference. A count captured at write time — "38 of 38 passing" — becomes false as soon as the suite grows, and the next agent will believe it and repeat it. A journal is the highest-trust artifact a fresh agent reads, so a wrong line in it costs more than a wrong line elsewhere.

## Safety and signal

Include only concise outcomes, decisions, verification evidence, commit references, issue IDs, and artifact pointers. Never include secrets, credential fragments, private tokens, large logs, duplicated plan prose, or unverified claims.

Redact a credential to a key name, an env-var reference, or an explicit placeholder. A redaction must not itself read as a credential; conforming redactions are expected to pass the guard.

The live journal is the hook contract. `SessionStart` injects its relative path, status, and complete next-step section. `Stop` checks freshness, mode-aware update guidance, one-shot loop protection, and secret-shaped content. Both are read paths with respect to the journal directory: neither creates it.

Freshness means the journal moved with the work. A timestamp that advances while the journal's content does not, in a session where other files changed, is not freshness.
