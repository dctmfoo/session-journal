# Session Journal

Give coding agents a memory between sessions: one small journal, a start hook that points to it, and a stop hook that keeps it current.

This pattern was hardened over months in private enterprise-delivery repositories, then rewritten as a clean, standalone project. It supports Claude Code and Codex with the same portable shell hooks, and it remains useful as an instruction-only discipline in other agent runtimes.

## What you get

- A fixed journal shape optimized for a fresh agent's first minute.
- THIN mode for work governed by a plan, and DETAILED mode for one-off work.
- `SessionStart` context containing the newest journal, status, and complete next step.
- A one-shot `Stop` nudge for missing or stale journals.
- A secrets guard that blocks common credential shapes without printing values.
- An agent-led adoption contract that surveys and adapts to the target repository.
- A deterministic, idempotent installer and uninstall path.

## 60-second agent install

In your repository, tell your agent:

> Read https://github.com/dctmfoo/session-journal/blob/main/ADOPT.md and install the session-journal discipline in this repo, adapted to how this repo works. Ask me only the questions ADOPT.md tells you to ask.

The contract makes the agent inspect your runtimes, instruction files, hooks, docs topology, timezone, ignore rules, and monorepo shape before it writes anything. It must merge rather than clobber and report a behavioral verification matrix.

For offline use:

```bash
npx degit dctmfoo/session-journal session-journal-source
# Or: git clone https://github.com/dctmfoo/session-journal.git
```

Then point your agent at the local `ADOPT.md`.

## Deterministic install

Run from a clone; the installer does not fetch code:

```bash
./install.sh /path/to/your-repo
./install.sh /path/to/your-repo --codex
./install.sh /path/to/your-repo --sessions-dir docs/sessions --codex
```

Options are `--sessions-dir <relative-path>`, `--codex`, `--no-claude`, and `--uninstall`. `jq` is required because settings are merged structurally. Invalid JSON or JSON5 is refused rather than rewritten.

Codex project hooks load only for trusted projects. After installation, open `/hooks` in Codex and review the new definitions; changed definitions require review again. Codex CLI 0.144.1 was verified with both `SessionStart` and turn-scoped `Stop`, so the same pointer, freshness nudge, and secrets guard run in Codex. The AGENTS.md block keeps a manual fallback for older or disabled hook surfaces.

## The journal in one glance

```markdown
**Status:** ACTIVE — installer tests are green

## Live plan pointer
docs/plans/release.md

## Next step for a fresh agent
Run the packaging check, then record the artifact hash here.
```

The pointer makes this THIN mode: details stay in the release plan. With `none`, the journal becomes DETAILED and carries the working record itself. See [the full specification](spec/session-journal-spec.md) and [template](templates/session-journal.md).

## Safety model

Journals are committed by default, so secret handling is deliberately strict. The Stop hook scans only the newest journal for JWT-like values, bearer values, credential assignments, and long hexadecimal strings. It reports line numbers, never matched values. A verified false-positive line can carry `<!-- journal-secrets-ok -->`; that escape applies only to that line.

This is a continuity aid, not a credential scanner for the whole repository. Keep your normal secret-scanning and review gates.

## Optional spine promotion

Long-running DETAILED journals often mean a durable plan is missing. The optional module under `extras/spine-promotion/` nudges after a configurable milestone count, then asks the agent to promote recurring work into a plan or specification and switch back to THIN.

## Uninstall

```bash
./install.sh /path/to/your-repo --codex --uninstall
```

The installer removes only its hook groups, scripts, and sentinel-delimited instruction blocks. It keeps journals because they are project history.

## FAQ

**Why not use conversation history?** A journal is runtime-neutral, reviewable in git, and written around current state and next action rather than transcript chronology.

**One journal per agent?** No. One per substantive human working session. A monorepo usually keeps one journal directory at its workspace root.

**Does Stop block forever?** No. Hook JSON uses `stop_hook_active`; empty-stdin runners get a one-shot marker fallback. The secrets guard still runs after the freshness nudge has been spent.

**Can journals be local-only?** Yes. The default is committed continuity, but ADOPT.md explicitly asks when ignore intent is ambiguous.

## License

MIT. See [LICENSE](LICENSE).
