# Session Journal

Give coding agents a memory between sessions. Each piece of work gets one small journal, and each journal is bound
to the session that writes it. Parallel sessions, worktrees, and lead/worker setups therefore stop reading, and
writing into, each other's journals.

It supports Claude Code and Codex with one dependency-free Python 3 script. In other agent runtimes it works as an
instruction-only discipline.

## What you get

- **A fixed journal shape**, built for a fresh agent's first minute. THIN mode is for work a plan governs; DETAILED
  mode is for one-off work.
- **Session binding.** A journal belongs to the session that first writes it. At start, a session is told the
  journal it is bound to. With no binding, it gets ranked candidates instead of "the newest file".
- **IN USE protection.** Writes into a journal that another live session owns are denied. The agent is told to
  start its own journal with a `**Continues:**` link.
- **Quiet nudges.** Stop asks for an update only when the turn landed work (an edit or a commit) and did not touch
  this session's journal, and at most once per turn. Read-only turns are never nudged.
- **Worktrees, `/clear`, and forks.** Journals stay in the main checkout. `/clear` offers the window's previous
  journal. A fork never inherits its parent's journal.
- **Lead and worker roles.** Workers write no journals. Their landed results reach the lead.
- **A credential check.** A journal write that looks like it carries a credential is denied, and the denial never
  shows the value.
- **A CLI** for continuity work: `candidates`, `find`, `reconstruct`, `list`, `health`, `scan`, `sweep`.
- **An agent skill** for the judgment calls the scripts cannot make: adopting, adapting, roles, migration, recall.
- **A doctor and an installer.** `doctor.sh` re-checks an installation at any time. The installer is idempotent,
  migrates v1 in place, and uninstalls cleanly.

## 60-second agent install

In your repository, tell your agent:

> Read https://github.com/dctmfoo/session-journal/blob/main/ADOPT.md and install the session-journal discipline in this repo, adapted to how this repo works. Ask me only the questions ADOPT.md tells you to ask.

`ADOPT.md` sends the agent through the `session-journal` skill (`skills/session-journal/SKILL.md`). The agent
surveys the repository's runtimes, instruction files, documentation, worktree habits, and ignore rules, runs the
installer, adapts the generated docs, and reports what the doctor printed.

For offline use:

```bash
npx degit dctmfoo/session-journal session-journal-source
```

Then point your agent at the local `ADOPT.md`. Pin a release tag rather than tracking `main` if you want a
reproducible install.

## Deterministic install

Run from a clone; the installer does not fetch code:

```bash
./install.sh /path/to/your-repo
```

| Option | Effect |
| --- | --- |
| `--sessions-dir <path>` | Journal directory, relative to the target repo. Default `sessions`. |
| `--plan-pointer <value>` | Default `## Live plan pointer` for the generated docs. Default `none` (DETAILED). |
| `--codex` | Also install Codex hooks, the Codex skill (`.agents/skills/`), and the `AGENTS.md` block. |
| `--no-claude` | Skip the Claude Code hooks, the Claude skill, and the `CLAUDE.md` block. |
| `--no-skill` | Do not install the agent skill. |
| `--refresh-docs` | Regenerate the sessions README, `TEMPLATE.md`, and instruction blocks, discarding local adaptations. |
| `--uninstall` | Remove the owned hooks, script, skills, local state, and instruction blocks. |

The installer needs `jq` because it merges settings structurally. It refuses invalid JSON or JSON5 rather than
rewriting it. Every refusal happens before the first byte is written. Agents need `python3` 3.8 or later. Every hook
command ends in `|| true`, so a missing interpreter disables the hooks instead of blocking the agent.

What it writes:

- `.claude/hooks/session-journal.py`: the single hook script.
- Six hook groups per runtime: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and
  `SessionEnd`.
- `<sessions>/README.md` and `<sessions>/TEMPLATE.md`.
- The skill.
- A sentinel-delimited block in `CLAUDE.md` and/or `AGENTS.md`.

Leases and traces live in `.claude/state/session-journal/`, which ignores itself.

Then commit the result. `.claude/`, `.codex/`, `.agents/`, and the journal directory carry the discipline to your
teammates. An install that exists only on your machine is not adopted.

Codex loads project hooks only for trusted projects. After installation, open `/hooks` in Codex and review the new
definitions.

## Upgrading from 1.x

```bash
./install.sh /path/to/your-repo          # same flags you installed with
./doctor.sh /path/to/your-repo
```

The installer does the following:

- Removes the v1 `session-journal-pointer.sh` and `session-journal-nudge.sh` scripts and their hook groups, and
  wires the new script.
- Keeps your journal directory, rewriting it as a relative `SESSION_JOURNAL_DIR` so linked worktrees resolve it to
  the main checkout.
- Keeps your adapted README, TEMPLATE, and instruction blocks.
- Drops the v1-only freshness variables.

No journal is renamed or rewritten. See [CHANGELOG.md](CHANGELOG.md) for what behaves differently.

## Check the installation

```bash
./doctor.sh /path/to/your-repo
```

Every failure mode here is silent by construction. A hook that never fires looks exactly like a quiet session. The
doctor checks that:

- the wiring is complete, and every command has its `|| true` safety net;
- no v1 hooks remain;
- Python is available and the installed script runs;
- the installation is committed and not ignored;
- local state stays out of git.

It then runs the real `SessionStart` and `Stop` hooks against a scratch state directory, scans every journal for
credential shapes, and reports hook errors logged on this machine. It exits non-zero on any failure, so it works in
CI.

## The journal in one glance

```markdown
**Status:** ACTIVE — installer tests are green
**Continues:** sessions/2026-03-02-0915-release-prep.md

## Live plan pointer
docs/plans/release.md

## Next step for a fresh agent
Run the packaging check, then record the artifact hash here.
```

The pointer makes this THIN mode: the details stay in the release plan. With `none`, the journal is DETAILED and
carries the working record itself. See [the specification](spec/session-journal-spec.md) and
[the template](templates/session-journal.md).

## The CLI

```bash
python3 .claude/hooks/session-journal.py candidates [words]   # bound journal, then open candidates (IN USE marked)
python3 .claude/hooks/session-journal.py find <words>         # search journals and the worker ledger
python3 .claude/hooks/session-journal.py reconstruct <journal> # next step, sessions that wrote it, Continues chain
python3 .claude/hooks/session-journal.py list [--all]         # sessions and their journals
python3 .claude/hooks/session-journal.py health               # drift indicators (JSON)
python3 .claude/hooks/session-journal.py scan [files]         # credential shapes; line numbers only
python3 .claude/hooks/session-journal.py sweep [hours] [--by-git] [--dry-run]   # pause idle ACTIVE journals
python3 .claude/hooks/session-journal.py role lead|worker | skip | release <sid> | bind <journal>
```

The session id defaults to `$CLAUDE_CODE_SESSION_ID` (Claude Code) or `$CODEX_THREAD_ID` (Codex); set `SESSION_JOURNAL_SESSION_ID` to override it.

## Configuration

Every setting is an environment variable. To make one apply to everyone, put it at the front of the generated hook
commands, where it travels with the repository; a re-run of the installer keeps it. To scope one to a single
session, set it in that agent's environment.

| Variable | Default | Effect |
| --- | --- | --- |
| `SESSION_JOURNAL_DIR` | `sessions` | Journal directory, relative to the main checkout. Set by `--sessions-dir`. |
| `SESSION_JOURNAL_STATE_DIR` | `.claude/state/session-journal` | Leases, ledger, and trace. |
| `SESSION_JOURNAL_SKIP` | unset | `1`: never nudge this session (a typo fix, a dependency bump). The credential check still runs. |
| `SESSION_JOURNAL_DISABLE` | unset | `1`: every hook does nothing. |
| `JOURNAL_ROLE` | `lead` | `worker`: never nudged; journal writes denied. |
| `JOURNAL_WORKER_PROMPT` | unset | Regex. A session whose first prompt matches is a soft worker: never nudged, writes allowed. |
| `JOURNAL_LANDING_BASH` | unset | Regex. Extra shell commands that count as landed work. `git commit` and `git push` always count. |
| `JOURNAL_SECRETS` | `deny` | `warn` turns the credential check into advice; `off` disables it. |
| `JOURNAL_LIVE_MIN` | `45` | Minutes a silent session still holds its journal. A running agent process holds it longer. |
| `JOURNAL_LIVE_MAX_H` | `24` | Cap on the process-alive hold. |
| `JOURNAL_NUDGE_MIN` | `20` | Minutes after which a landed turn is nudged even without a commit. |
| `JOURNAL_MAX_KB` | `40` | Size above which an agent is told to continue in a new journal. |
| `JOURNAL_PAUSE_ON_END` | `1` | `0`: a session ending does not mark its ACTIVE journal PAUSED. |
| `JOURNAL_TRANSCRIPTS_DIR` | `~/.claude/projects` | Where `reconstruct` looks for transcripts. |
| `SPINE_PROMOTION_THRESHOLD` | unset (off) | Milestone count at which a DETAILED journal is asked, once, to be promoted to a plan. |
| `SPINE_PROMOTION_TARGET_HINT` | `docs/plans/` | Where that plan should go. |

## Safety model

Journals are committed by default, so credential handling is strict. `PreToolUse` scans the new text of every
journal write, whether it comes from an edit, `apply_patch`, or a shell write. It looks for:

- provider token shapes, JWTs, bearer values, and private-key headers;
- storage keys and signed URLs;
- credentials embedded in URLs;
- `key: value` assignments whose key names a secret;
- passwords stated in prose or in table cells.

For named keys the *value* is inspected. The redactions the check asks for therefore pass: `<redacted>`,
`$API_TOKEN`, `stored-in-ci-secrets`, `redacted (32 chars)`. So do identifiers and references. The denial names
lines and rules, never values. `<!-- journal-secrets-ok -->` exempts a line a human has verified.

This is a continuity aid, not a repository credential scanner. Keep your normal secret-scanning gates. See
[SECURITY.md](SECURITY.md).

## Optional spine promotion

Long-running DETAILED journals often mean a durable plan is missing. Set `SPINE_PROMOTION_THRESHOLD` (for example
`6`) on the generated Stop command. When this session's own DETAILED journal reaches that many milestones, Stop asks
once per journal for the work to be promoted into a plan under `SPINE_PROMOTION_TARGET_HINT` (default
`docs/plans/`), and for the journal to switch to THIN. It is off by default. The 1.x shell module
`extras/spine-promotion/` is gone: the installer removes its Stop entry and carries its settings over.

## Uninstall

```bash
./install.sh /path/to/your-repo --codex --uninstall
```

This removes the owned hook groups (v1 and v2), the script, the skills, local state, and the instruction blocks. It
keeps journals, their README, and `TEMPLATE.md`, because they are project history.

## Troubleshooting

**The agent says nothing about journals at start.** `SessionStart` is not firing. Run `./doctor.sh`. Likely causes:

- an uncommitted or ignored `.claude/`;
- no `python3` on the agent's `PATH`;
- a missing journal directory (the hooks never create it).

**The agent appended to someone else's journal.** It wrote before the other session bound it, or the other session
had been silent for more than `JOURNAL_LIVE_MIN` with no running process. Check with
`python3 .claude/hooks/session-journal.py list --all`.

**A write was denied as IN USE, but that session is gone.** Run
`python3 .claude/hooks/session-journal.py release <sid>`.

**A write was denied for a credential that is not one.** Redact the value to a reference. If a human confirms the
line is clean, append `<!-- journal-secrets-ok -->`.

**Workers keep getting nudged.** Start them with `JOURNAL_ROLE=worker`, or set `JOURNAL_WORKER_PROMPT` to match your
orchestrator's dispatch prompt.

**A trivial session demands a journal.** Run `python3 .claude/hooks/session-journal.py skip`, or start the agent
with `SESSION_JOURNAL_SKIP=1`.

**A teammate cloned the repo and none of this works for them.** `.claude/` is probably ignored or uncommitted.
`./doctor.sh` reports it.

## FAQ

**Why not use conversation history?** A journal is runtime-neutral, reviewable in git, and written around current
state and next action rather than transcript order.

**One journal per agent?** One per piece of work, owned by one live session at a time. Workers report to a lead,
whose journal records the outcome.

**Why is there a state directory now?** Binding needs to know which session wrote what. The state is small JSON,
local to the machine, and ignores itself. Losing it costs live IN USE locks, never journal content.

**Why Python instead of shell?** Six events, transcript parsing, locking, and a CLI did not fit in portable shell.
The script uses the standard library only, and runs with Python 3.8 or later.

## License

MIT. See [LICENSE](LICENSE).
