# Session Journal

Give coding agents a memory between sessions: one small journal, a start hook that points to it, and a stop hook that keeps it current.

This pattern was hardened over months in private enterprise-delivery repositories, then rewritten as a clean, standalone project. It supports Claude Code and Codex with the same portable shell hooks, and it remains useful as an instruction-only discipline in other agent runtimes.

## What you get

- A fixed journal shape optimized for a fresh agent's first minute.
- THIN mode for work governed by a plan, and DETAILED mode for one-off work.
- `SessionStart` context containing the live journal, its status, and complete next step.
- A one-shot `Stop` nudge for missing or stale journals.
- A secrets guard that blocks common credential shapes without printing values.
- A re-runnable `doctor.sh` self-check, because a hook that stops firing is silent.
- An agent-led adoption contract that surveys and adapts to the target repository.
- A deterministic, idempotent installer and uninstall path.

## 60-second agent install

In your repository, tell your agent:

> Read https://github.com/dctmfoo/session-journal/blob/main/ADOPT.md and install the session-journal discipline in this repo, adapted to how this repo works. Ask me only the questions ADOPT.md tells you to ask.

The contract makes the agent inspect your runtimes, instruction files, hooks, docs topology, timezone, ignore rules, and monorepo shape before it writes anything. It must merge rather than clobber and report a behavioral verification matrix.

For offline use:

```bash
npx degit dctmfoo/session-journal session-journal-source
```

Then point your agent at the local `ADOPT.md`. Pin a release tag rather than tracking `main` if you want a reproducible install.

## Deterministic install

Run from a clone; the installer does not fetch code:

```bash
./install.sh /path/to/your-repo
```

| Option | Effect |
| --- | --- |
| `--sessions-dir <path>` | Journal directory, relative to the target repo. Default `sessions`. |
| `--plan-pointer <value>` | Default `## Live plan pointer` for the generated docs. Default `none` (DETAILED). Give it a path to start in THIN mode. |
| `--codex` | Also install Codex hooks and the `AGENTS.md` block. |
| `--no-claude` | Skip the Claude Code hooks and the `CLAUDE.md` block. |
| `--refresh-docs` | Regenerate the sessions README, `TEMPLATE.md`, and instruction blocks, discarding local adaptations. |
| `--uninstall` | Remove the owned hooks, scripts, and instruction blocks. |

`jq` is required because settings are merged structurally. Invalid JSON or JSON5 is refused rather than rewritten. Every refusal happens before the first byte is written, so a refused install never leaves hooks half-wired.

Then commit the result. `.claude/` and the journal directory are what carry the discipline to your teammates; an install that only exists on your machine is not adopted.

Codex project hooks load only for trusted projects. After installation, open `/hooks` in Codex and review the new definitions; changed definitions require review again. Codex CLI 0.144.1 was verified with both `SessionStart` and turn-scoped `Stop`, so the same pointer, freshness nudge, and secrets guard run in Codex. The AGENTS.md block keeps a manual fallback for older or disabled hook surfaces.

## Check the installation

```bash
./doctor.sh /path/to/your-repo
```

Every failure mode in this project is silent by construction: a `SessionStart` hook that never fires looks exactly like a session with no journal, and a `Stop` hook that never fires looks exactly like a journal that is always fresh. The doctor re-runs the adoption verification matrix at any time, and checks what adoption cannot: whether the installation is committed, whether a teammate will actually receive it, whether the registered command still resolves, and which journal the pointer would deliver right now. It exits non-zero if anything fails, so it works in CI.

## Updating

Re-run the installer from a fresh clone:

```bash
./install.sh /path/to/your-repo
```

The rerun preserves your adapted `sessions/README.md`, your `TEMPLATE.md`, your instruction block, and any environment overrides on the generated commands, printing a line for each thing it keeps. Pass `--refresh-docs` when you want the upstream wording back. Check [CHANGELOG.md](CHANGELOG.md) for upgrade notes, then run `./doctor.sh`.

## The journal in one glance

```markdown
**Status:** ACTIVE — installer tests are green

## Live plan pointer
docs/plans/release.md

## Next step for a fresh agent
Run the packaging check, then record the artifact hash here.
```

The pointer makes this THIN mode: details stay in the release plan. With `none`, the journal becomes DETAILED and carries the working record itself. See [the full specification](spec/session-journal-spec.md) and [template](templates/session-journal.md).

Set `**Status:** DONE` when the work is finished. A DONE journal is background, not the live frontier — the next session starts clean instead of inheriting a completed next step.

## Configuration

Every setting is an environment variable on the generated hook command, so it lives in your settings file and travels with the repository.

| Variable | Default | Effect |
| --- | --- | --- |
| `SESSION_JOURNAL_DIR` | `<repo>/sessions` | Journal directory. Set by `--sessions-dir`. |
| `JOURNAL_FRESH_SECS` | `300` | How old the newest journal may be before `Stop` nudges. |
| `SESSION_JOURNAL_SKIP` | unset | Set to `1` for a session that genuinely needs no journal — a typo fix, a dependency bump. The secrets guard still runs. |
| `JOURNAL_REQUIRE_CONTENT_CHANGE` | `1` | Require the journal's content to have changed when other files did, not just its timestamp. Set to `0` for mtime-only freshness. |
| `JOURNAL_STOP_MARKER_TTL_SECS` | `60` | How long the one-shot loop marker stays valid, for runners that supply no stdin. |

## Safety model

Journals are committed by default, so secret handling is deliberately strict. The Stop hook scans only the newest journal for JWT-like values, bearer values, credential assignments, provider-token shapes, private-key headers, and long hexadecimal strings. It reports line numbers, never matched values.

Self-identifying shapes are always flagged. For a `key: value` assignment the *value* is inspected, not just the key name, so the redactions this guard asks for — `<redacted>`, `$STRIPE_API_KEY`, `redacted (32 chars)`, `stored-in-ci-secrets` — are accepted rather than blocking the agent in a redact-and-reblock loop. A bare hexadecimal string is flagged only away from digest context: if the line, the line above, or the line below mentions a digest, hash, checksum, fingerprint, commit, revision, blob, oid, or etag *as a whole word*, the value is treated as verifiable evidence and left alone. A remaining false positive can carry `<!-- journal-secrets-ok -->`, and that escape applies only to its own line.

This is a continuity aid, not a credential scanner for the whole repository. Keep your normal secret-scanning and review gates. See [SECURITY.md](SECURITY.md).

## Optional spine promotion

Long-running DETAILED journals often mean a durable plan is missing. The optional module under `extras/spine-promotion/` nudges after a configurable milestone count, then asks the agent to promote recurring work into a plan or specification and switch back to THIN. It is an intentionally manual add-on: the core installer and uninstaller do not manage its Stop entry.

## Uninstall

```bash
./install.sh /path/to/your-repo --codex --uninstall
```

The installer removes only its hook groups, scripts, and sentinel-delimited instruction blocks. It keeps journals, their README, and `TEMPLATE.md` because they are project history.

## Troubleshooting

Indexed by what you actually observe.

**The agent starts a session and says nothing about a journal.** The `SessionStart` hook is not firing. Run `./doctor.sh` — the likely causes are an uncommitted or gitignored `.claude/`, an install into a subdirectory rather than the repository root, or a hook script that lost its executable bit.

**The agent was handed an old journal.** Fixed in 1.1.0: selection used to be decided by mtime alone, and a fresh clone gives every journal the same timestamp, which kept the alphabetically oldest one. Upgrade, then confirm with `./doctor.sh`, which reports which journal the pointer would deliver.

**A fresh agent is told there is no work left.** The newest journal is `DONE`. Since 1.1.0 the pointer prefers the newest `ACTIVE` or `BLOCKED` journal and, when every journal is closed, says so rather than replaying a finished next step.

**`Stop` keeps blocking no matter what the agent writes.** The secrets guard is matching something. It runs ahead of the loop protection by design, so `stop_hook_active` will not clear it. The message names the line numbers; redact the value to a key name, an env-var reference, or `<redacted>`. If the line is a verified false positive, append `<!-- journal-secrets-ok -->` to it.

**`Stop` nudges even though the journal was just updated.** Since 1.1.0 the gate requires content to change, not just the timestamp, when other files in the repository changed. If your workflow legitimately touches without editing, set `JOURNAL_REQUIRE_CONTENT_CHANGE=0`.

**Every trivial session demands a journal.** Set `SESSION_JOURNAL_SKIP=1` for that session.

**A teammate cloned the repo and none of this works for them.** `.claude/` is probably gitignored or was never committed. `./doctor.sh` reports this explicitly.

## FAQ

**Why not use conversation history?** A journal is runtime-neutral, reviewable in git, and written around current state and next action rather than transcript chronology.

**One journal per agent?** No. One per substantive human working session. A monorepo usually keeps one journal directory at its workspace root.

**Does Stop block forever?** No. Hook JSON uses `stop_hook_active`; empty-stdin runners get a short-lived marker fallback. The secrets guard still runs after the freshness nudge has been spent, and it is the one thing that can block repeatedly — deliberately, because the alternative is committing a credential.

**Can journals be local-only?** Yes. The default is committed continuity, but ADOPT.md explicitly asks when ignore intent is ambiguous. `./doctor.sh` will tell you which you have.

**Why is there no database?** Because the journal is the compression. It is written by an agent, read by a human, reviewed in a pull request, and carried by git. A store would add a runtime, a migration story, and a corruption story to a project whose entire value is that it has none of those.

## License

MIT. See [LICENSE](LICENSE).
