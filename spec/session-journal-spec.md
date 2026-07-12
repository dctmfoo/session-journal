# Session Journal Specification

Version 1.0

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

`Next step for a fresh agent` is mandatory and concrete. Name the next command, file, test, decision, or owner action.

## Modes

The first non-empty line under `## Live plan pointer` selects the mode:

- A real artifact path means **THIN**. The journal indexes outcomes and evidence without retelling the artifact.
- `none`, an empty section, or a missing section means **DETAILED**. The journal is the canonical working record.

Recurring DETAILED work should be promoted into a durable plan, specification, ADR, runbook, or tracker; future journals then point to it in THIN mode.

## Lifecycle

Create a journal once intent is clear. Continue the same work in the same file even across days. Start unrelated work in a new file. After manual or automatic context compaction, reread the newest journal and governing artifact before taking action.

Update `Last updated`, the one-line status, evidence, current state, next step, and change log before the end of every resumable turn. A Stop hook may treat a journal older than five minutes as stale; repositories can configure that window.

## Safety and signal

Include only concise outcomes, decisions, verification evidence, commit references, issue IDs, and artifact pointers. Never include secrets, credential fragments, private tokens, large logs, duplicated plan prose, or unverified claims.

The newest journal is the hook contract. `SessionStart` injects its relative path, status, and complete next-step section. `Stop` checks freshness, mode-aware update guidance, one-shot loop protection, and secret-shaped content.
