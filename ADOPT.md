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
7. Ignore rules: journals are intended to be committed. Warn if an existing rule ignores the chosen directory, then ask Question 2 only if intent remains unclear. Check `.claude/` too — a repository that ignores it will silently give the hooks to nobody but the installing machine.
8. Repository root: the installer refuses to install into a subdirectory of a git repository, because the generated hook commands resolve their own root at runtime. Confirm you are targeting the root.

Before writing, ask Question 3 unless the user's request already says whether to install the optional spine-promotion module. Do not infer opt-in or opt-out from repository shape.

## Phase B — install and adapt

1. Prefer the tested installer instead of rebuilding its merge logic. Clone or download this repository to a temporary location, then run `./install.sh <target>` with the discovered `--sessions-dir`, `--plan-pointer`, `--codex`, and/or `--no-claude` flags. If the installer cannot run, perform the equivalent steps below manually and explain why in the final report.
2. The installer puts one real copy of both scripts in `.claude/hooks/`, merges `SessionStart` and `Stop` without replacing existing groups, and uses runtime-relative commands so subdirectory starts and relocated clones work. It also writes `<sessions>/README.md` and `<sessions>/TEMPLATE.md`. Project-local Codex hooks require a trusted project and hook review through `/hooks`.
3. Pass `--plan-pointer <path>` when Phase A found a strong governing artifact, so the generated docs start in THIN mode rather than contradicting your own survey.
4. Adapt the generated sessions README with the strongest THIN default, the `date +%Z` result, and repository-specific evidence vocabulary. Adapt `TEMPLATE.md` if the repository needs extra sections. A later re-run of the installer preserves both; it will say so, and only `--refresh-docs` overwrites them.
5. Adapt the sentinel-delimited blocks in CLAUDE.md and AGENTS.md. Keep the twin-sync sentence only when both instruction files exist. Instruction-only runtimes need the manual end-of-turn check. A re-run preserves your edits inside the sentinels.
6. Set `JOURNAL_FRESH_SECS` in the generated hook commands only when the repository needs a non-default freshness window. A re-run preserves environment overrides you add here.
7. If Question 3 opted into spine promotion, merge `extras/spine-promotion/journal-spine-promotion-nudge.sh` as an additional Stop handler and test it. This optional handler is manually managed and must also be removed manually; the core installer intentionally owns only its pointer and freshness/secrets hooks.

Never delete or rewrite an existing user hook. Never commit unless the user asked or repository conventions already authorize it. Never put a real or realistic credential in a demonstration journal. If a settings file contains comments or JSON5, do not normalize or overwrite it: show the matching snippet and ask the user to merge it manually.

## Phase C — verify before finishing

Run `./doctor.sh <target>` and include its output in your report. It must exit 0 except for the "installation is committed" check, which Phase D resolves. It covers installation integrity, command resolution, journal-directory contents, git reachability, and a live pointer and Stop run.

Then run the behavioral cases the doctor cannot construct for you:

| Check | Expected proof |
| --- | --- |
| Empty pointer | With no journal present, SessionStart returns valid JSON with a create instruction naming `TEMPLATE.md` |
| Populated pointer | A synthetic journal yields its relative path, Status, and complete next step |
| DONE handling | A synthetic `**Status:** DONE` journal is reported as finished, not replayed as the live next step |
| Fresh Stop | Fresh journal plus `{"stop_hook_active":false}` exits 0 |
| Stale Stop | Old THIN and DETAILED fixtures exit 2 with mode-correct guidance |
| Loop protection | `{"stop_hook_active":true}` skips freshness and exits 0 |
| Secrets guard | Construct a synthetic credential assignment at runtime; Stop exits 2 without echoing the value |
| Redaction accepted | Replacing that value with `<redacted>` exits 0, so the prescribed fix actually clears the block |

Delete verification fixtures. Then write the first real journal about this adoption session, with no secrets, and run the pointer once more so the install demonstrates itself.

For Codex, trust the project, review the changed hooks with `/hooks`, and verify behavior with the installed Codex version. For Claude Code, run a small headless task if available. If a runtime cannot be exercised, say so and retain the manual fallback wording; never claim an unobserved hook fired.

## Phase D — hand it to the team

An installation that exists only on one machine is not adopted. Unless the user declined committing:

1. Commit `.claude/` (or `.codex/`), the instruction-file blocks, and the journal directory together, so a teammate's first clone arrives with the discipline already wired.
2. Confirm no ignore rule excludes them. `./doctor.sh` fails explicitly when the hook settings are gitignored or uncommitted.
3. Tell the user what a teammate must do on first clone — normally nothing, which is the point — and that `./doctor.sh` is how anyone checks later, since a hook that stops firing is otherwise silent.
4. Mention `SESSION_JOURNAL_SKIP=1` for sessions that genuinely need no journal. Without it, the team learns to route around the Stop hook, and the discipline dies quietly.

## Phase E — document reversal

Uninstalling removes the two owned hook groups, the two installed scripts, and the sentinel-delimited instruction blocks. It keeps the journal directory, its README, and TEMPLATE.md by default because they are project history. The deterministic installer performs this with `./install.sh <repo> --uninstall` using the same runtime flags used for installation.

Upgrading is the same command as installing: re-run `./install.sh <repo>` from a fresh clone. The re-run preserves the adapted README, TEMPLATE, instruction blocks, and environment overrides, and reports each thing it kept.

## Final report

Report the survey decisions, changed files, the `./doctor.sh` output, the behavioral matrix, any runtime limitation, first-journal path, whether the install was committed, and the uninstall command. Mention any question that used the three-question budget.
