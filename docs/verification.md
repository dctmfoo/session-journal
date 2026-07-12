# Verification record

Verified 2026-07-13 on macOS. This document records observed behavior, not just intended configuration.

## Automated suites

| Gate | Result |
| --- | --- |
| Shell syntax | `bash -n` passed for the installer, both core hooks, and the optional spine-promotion hook |
| JSON syntax | Both hook snippets parsed with `jq` |
| bats-core 1.13.0 | 25/25 checks passed |
| Installer lifecycle | Fresh install, merge preservation, idempotent rerun, custom journal path, Codex wiring, and uninstall passed |
| Secrets behavior | Four pattern classes, safe negatives, one-line allowlist, and guard-under-loop-protection passed |

The first proof-first run intentionally had 25 failures because the hooks and installer did not exist yet. The same suites passed after implementation.

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

Also run the project-specific trace grep and manually read every tracked file. The final gate results and public CI URL are added below when publishing completes.
