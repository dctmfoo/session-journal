# Verification record

This document records observed behavior, not just intended configuration. It has
two parts: a **dated adoption record** that is a snapshot and is never rewritten,
and a **current gates** section that must stay true today. Counts inside the
dated record describe the revision they were taken at; counts in the current
section are checked by `tests/docs.bats`, so they cannot quietly rot.

## Current gates

Run these to reproduce the claim rather than trusting a number frozen here:

```bash
bash -n install.sh doctor.sh extras/spine-promotion/*.sh
shellcheck install.sh doctor.sh extras/spine-promotion/*.sh
python3 -m unittest discover -s tests -p 'test_*.py'
bats tests
./doctor.sh .
```

| Gate | Claim |
| --- | --- |
| Python scenario tests | <!-- unittest-count -->53<!-- /unittest-count --> scenario methods in `tests/test_journal.py` (the session-binding class runs twice, once under `docs/sessions`), all passing |
| bats-core | <!-- bats-count -->66<!-- /bats-count --> checks, all passing |
| Shellcheck and `bash -n` | clean for every shell entrypoint |
| Self-check | `./doctor.sh .` passes against this repository's own installation |
| Secrets | the runtime guard runs over every tracked journal in CI, plus a pinned full-history gitleaks scan |

## 2.0.0 record — 2026-10-21, macOS

A snapshot, never rewritten. Python 3.14 and Claude Code 2.1.306 / Codex CLI 0.163.0 were installed on the machine.

- The scenario suite and the bats suite passed at the revision that introduced 2.0.0. Re-run the commands under
  **Current gates** for today's counts.
- The installer ran twice into a fresh scratch repository under `/tmp` (with and without `--codex`), then into a
  scratch v1 installation, which it migrated. `./doctor.sh` passed on each.
- Simulated sessions piped hook JSON into the installed script: start, edit, commit, Stop nudge, journal write,
  Stop quiet, SessionEnd.
- **Live Claude Code 2.1.306** (headless `claude -p`, Haiku, scratch repository with a 2.0 install): the stream
  recorded `hook_started`/`hook_response` for SessionStart, PreToolUse, PostToolUse and Stop. The hook trace showed
  `SessionStart` → `bind` (the agent's journal write) → `stop: fresh` → `SessionEnd`, which stamped the journal's
  `**Sessions:**` line and set it `PAUSED`. In the session that built this release, the installed PreToolUse hook
  also denied a journal write by a `JOURNAL_ROLE=worker` session, as designed.
- **Live Codex CLI 0.163.0** (`codex exec`, scratch repository, `--dangerously-bypass-hook-trust` for that one
  invocation): PostToolUse recorded the `apply_patch` edit and the `git commit` under Codex's turn id; Stop nudged
  once ("this turn landed work but this session has no journal yet"); the continuation's Stop was skipped as
  `already-nudged`; SessionEnd fired. Codex's own transcript is not parsed: the hooks' turn record carried it.
- Not exercised live: IN USE between two concurrent live sessions, `/clear`, and forks. The scenario suite covers
  them with synthetic hook input.

## Adoption record — 2026-07-13, macOS (1.0, shell hooks)

## Automated suites

| Gate | Result |
| --- | --- |
| Shell syntax | `bash -n` passed for the installer, both core hooks, and the optional spine-promotion hook |
| JSON syntax | Both hook snippets parsed with `jq` |
| bats-core 1.13.0 | 38/38 checks passed at that revision |
| Installer lifecycle | Fresh install, merge preservation, idempotent rerun, portable custom journal path, Codex-only wiring, invalid-input refusal, and repeatable uninstall passed |
| Secrets behavior | Credential and provider pattern classes, safe negatives, one-line allowlist, and guard-under-loop-protection passed |
| Optional spine promotion | Empty, THIN, below-threshold, threshold, and configured-override cases passed |

The first proof-first run intentionally had 25 failures because the hooks and installer did not exist yet. The suite grew to 38 checks during review; all passed after implementation and hardening. It has grown since: see **Current gates** above for the live count.

## Live Claude Code

Version: Claude Code 2.1.207, Sonnet.

In a fresh git fixture installed with the Claude hook configuration:

1. `SessionStart` fired and returned successful JSON instructing creation of the first journal.
2. The agent created an exact five-byte sample file and a DETAILED journal.
3. `Stop` fired with exit 0 and `{}` after the journal was fresh.
4. A second headless run was told not to inspect files. It still reported the injected journal path, one-line status, and complete next step, proving that the data came from `SessionStart` context.

The streamed hook events recorded both `hook_started` and successful `hook_response` events for `SessionStart` and `Stop`.

## Live Codex CLI

Version: Codex CLI 0.144.1.

Current behavior was checked against the official [Codex hooks guide](https://learn.chatgpt.com/docs/hooks) and [advanced configuration guide](https://developers.openai.com/codex/config-advanced#hooks). The project was trusted in an isolated configuration and hook trust was bypassed only for the scripted verification invocation.

Observed results:

1. On a fresh run, the agent created a sample file and journal.
2. On a second run that prohibited file inspection, the agent reported the exact journal path, status, and next step supplied by `SessionStart`.
3. After the journal mtime was made stale, `Stop` continued the turn. A cooperative prompt caused the agent to refresh the journal and then finish a second time.
4. A deliberately conflicting prompt demonstrated one-shot behavior: Codex continued once, then `stop_hook_active` prevented a loop.

This confirms that current Codex supports both required lifecycle surfaces. The AGENTS.md manual fallback remains useful for older clients, disabled hooks, untrusted projects, or hooks awaiting review.

## Context-free adoption trials

Each fixture began with only this instruction:

> Read ADOPT.md and install the session-journal discipline in this repo, adapted to how this repo works. Ask me only the questions ADOPT.md tells you to ask.

| Fixture | Expected adaptation | Observed result |
| --- | --- | --- |
| Empty greenfield git repo | Root `sessions/`, DETAILED default, Codex instructions and hooks, local timezone | Passed after the agent asked the optional-module question; used `IST` from `date +%Z`, wrote the first real journal, and completed the full behavior matrix |
| Docs-heavy repo with an existing Claude Stop hook | Preserve the hook, use the active plan as THIN default, sync Claude and Codex instructions | Passed; existing handler remained, `docs/plans/current.md` became the THIN default, and all verification cases passed |
| Minimal monorepo with AGENTS.md only | One workspace-root journal directory, preserve instructions, add dual-runtime wiring | Passed; root `sessions/` was selected, core-only choice was honored, and all verification cases passed |

The first greenfield trial exposed an ambiguous timezone instruction: the agent chose UTC. ADOPT.md was tightened to require `date +%Z` and forbid `date -u`; the context-free trial was rerun from an empty repository and passed with the machine-local label.

## Security and publication gates

Before publication, run both forms so uncommitted content and full history are covered:

```bash
gitleaks detect --source . --no-git --redact
gitleaks detect --source . --log-opts="--all" --redact
```

Also run the project-specific trace grep and manually read every tracked file.

Pre-publication result after the final review fix:

- Uncommitted-tree scan: clean.
- Full-history scan across all pre-publication commits: clean.
- Customer and personal-trace grep: zero matches.
- Manual review: all 28 tracked files read; examples are synthetic and no private source file was copied.
- Shellcheck and `bash -n`: clean for every shell entrypoint.
- bats-core: 38/38 passing at that revision, including review regressions for path traversal, portable relocation, malformed JSON, sentinel integrity, repeatable uninstall, and spine promotion.
- Relocation fixture: a custom `docs/sessions/` install still resolved and returned valid pointer JSON after the target repo moved to a different absolute path containing spaces.
- Structured code review: installer command injection/path escape and portability findings fixed; CI now repeats shellcheck, tracked-journal guarding, bats, and full-history gitleaks.

Hosted CI is green on Ubuntu, macOS, and the full-history gitleaks job: [run 29213884686](https://github.com/dctmfoo/session-journal/actions/runs/29213884686).
