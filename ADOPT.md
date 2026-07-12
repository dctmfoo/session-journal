# Agent Adoption Contract

You are installing the Session Journal discipline into a target repository. Adapt it to the repository you actually find. Preserve existing configuration and prove the result before finishing.

Ask at most three questions, and only when discovery cannot answer them:

1. Which journal directory should be used, if both root `sessions/` and `docs/sessions/` are equally plausible?
2. Should journals be committed (the default) or ignored locally?
3. Should the optional spine-promotion nudge be installed?

## Phase A — survey without writing

Inspect and record for your final report:

1. Agent runtimes: `.claude/settings.json`, `.codex/config.toml`, `.codex/hooks.json`, and instruction-only runtimes such as Cursor or Copilot. Treat user-level configuration as a clue, never as permission to modify global files.
2. Instruction files: CLAUDE.md, AGENTS.md, both, or neither. Inventory existing hooks and plan a merge; never replace a hooks array.
3. Documentation topology: plans, specifications, ADRs, runbooks, or an issue tracker. Use the strongest active artifact as the default THIN pointer. With no docs culture, default to DETAILED and `none`.
4. Journal location: default to root `sessions/`; prefer `docs/sessions/` when the repository consistently keeps process docs under `docs/` or tightly controls published root files. A monorepo normally gets one workspace-root journal directory because a journal follows the human session, not a package.
5. Timezone: run `date +%Z` in the target repository and use that machine-local zone label. Do not use `date -u`, `UTC` by convention, or a zone inherited from this upstream repository.
6. Repository vocabulary: add branch lines for multi-repository work and name relevant issue, gate, ADR, or test identifiers in the local evidence guidance.
7. Ignore rules: journals are intended to be committed. Warn if an existing rule ignores the chosen directory, then ask Question 2 only if intent remains unclear.

Before writing, ask Question 3 unless the user's request already says whether to install the optional spine-promotion module. Do not infer opt-in or opt-out from repository shape.

## Phase B — install and adapt

1. Prefer the tested installer instead of rebuilding its merge logic. Clone or download this repository to a temporary location, then run `./install.sh <target>` with the discovered `--sessions-dir`, `--codex`, and/or `--no-claude` flags. If the installer cannot run, perform the equivalent steps below manually and explain why in the final report.
2. The installer puts one real copy of both scripts in `.claude/hooks/`, merges `SessionStart` and `Stop` without replacing existing groups, and uses runtime-relative commands so subdirectory starts and relocated clones work. Project-local Codex hooks require a trusted project and hook review through `/hooks`.
3. Adapt the generated sessions README with the strongest THIN default, the `date +%Z` result, and repository-specific evidence vocabulary. Keep the generated directory accurate.
4. Adapt the sentinel-delimited blocks in CLAUDE.md and AGENTS.md. Keep the twin-sync sentence only when both instruction files exist. Instruction-only runtimes need the manual end-of-turn check.
5. Set `JOURNAL_FRESH_SECS` in the generated hook commands only when the repository needs a non-default freshness window. The core installer does not manage this optional override.
6. If Question 3 opted into spine promotion, merge `extras/spine-promotion/journal-spine-promotion-nudge.sh` as an additional Stop handler and test it. This optional handler is manually managed and must also be removed manually; the core installer intentionally owns only its pointer and freshness/secrets hooks.

Never delete or rewrite an existing user hook. Never commit unless the user asked or repository conventions already authorize it. Never put a real or realistic credential in a demonstration journal. If a settings file contains comments or JSON5, do not normalize or overwrite it: show the matching snippet and ask the user to merge it manually.

## Phase C — verify before finishing

Run and report this matrix:

| Check | Expected proof |
| --- | --- |
| Static scripts | `bash -n` succeeds; both scripts are executable |
| Settings | `jq .` succeeds for each modified JSON file; pre-existing hooks remain |
| Empty pointer | Direct SessionStart run returns valid JSON with a create instruction |
| Populated pointer | A synthetic journal yields its relative path, Status, and complete next step |
| Fresh Stop | Fresh journal plus `{"stop_hook_active":false}` exits 0 |
| Stale Stop | Old THIN and DETAILED fixtures exit 2 with mode-correct guidance |
| Loop protection | `{"stop_hook_active":true}` skips freshness and exits 0 |
| Secrets guard | Construct a synthetic credential assignment at runtime; Stop exits 2 without echoing the value |

Delete verification fixtures. Then write the first real journal about this adoption session, with no secrets, and run the pointer once more so the install demonstrates itself.

For Codex, trust the project, review the changed hooks with `/hooks`, and verify behavior with the installed Codex version. For Claude Code, run a small headless task if available. If a runtime cannot be exercised, say so and retain the manual fallback wording; never claim an unobserved hook fired.

## Phase D — document reversal

Uninstalling removes the two owned hook groups, the two installed scripts, and the sentinel-delimited instruction blocks. Keep the journal directory by default because it is project history. The deterministic installer performs this with `./install.sh <repo> --uninstall` using the same runtime flags used for installation.

## Final report

Report the survey decisions, changed files, exact verification matrix, any runtime limitation, first-journal path, and uninstall command. Mention any question that used the three-question budget.
