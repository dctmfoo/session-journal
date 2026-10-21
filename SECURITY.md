# Security policy

## What this project does to your repository

`install.sh` copies one Python script, `.claude/hooks/session-journal.py`, into your repository. It wires that
script into six hook events in your agent settings: `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `Stop`, and `SessionEnd`. From then on, your agent runtime runs it automatically, with your
permissions. Read it before you install it: it uses the Python standard library only, and it runs no network code.

What the script writes at runtime:

- **Leases, a worker ledger, and a trace** in `.claude/state/session-journal/`. This directory ignores itself
  (`.gitignore` containing `*`). It records session ids, worktree and branch names, transcript paths, the first
  200 characters of a worker's first prompt, and a worker's last reply (up to 400 characters). It never leaves the
  machine unless you copy it.
- **Two header lines in journals**, when a session ends with no other live session owning the journal: it appends
  the session to `**Sessions:**`, and turns `ACTIVE` into `PAUSED` (set `JOURNAL_PAUSE_ON_END=0` to keep the
  status). `sweep` changes `ACTIVE` to `PAUSED` only when you run it.

The installer never fetches code. It only copies from the clone you run it from.

## What the credential check is, and is not

`PreToolUse` scans the **new text** of each journal write: an editing tool, `apply_patch`, or a recognisable shell
write. It looks for credential shapes and denies the write when one matches. The denial names line numbers and rule
names, never the matched value, so the hook cannot leak a secret into a transcript. A shell command can hide both
its target and its content (`cat notes > "$F"`), so after any shell command that changed a journal, `PostToolUse`
scans the journal file itself. A match cannot be denied after the fact: the agent is told to remove it, and in
`deny` mode Stop blocks until the journal is clean. `scan` and `./doctor.sh` apply the same rules to every journal on
disk.

It is a continuity aid, not a credential scanner:

- It scans journal writes, not your repository.
- It matches shapes. It will miss a secret that does not look like one: a passphrase in plain prose, a credential
  split across lines, or an encoded blob.
- For named keys it inspects the value. To keep redactions from re-triggering the check, it exempts values shorter
  than 6 characters, identifiers (`app-secret`, `stored-in-ci-secrets`, `ENV_VAR_NAME`, dotted property names),
  paths and URLs, plain words, and placeholders (`<...>`, `$VAR`, `${...}`, `***`, `REDACTED`). A real credential
  that looks like one of those will be missed.
- A shell write the hook cannot recognise as a journal write is not scanned before it runs. `scan` finds the result
  afterwards.
- Unlike 1.x, it no longer flags bare 40+ character hexadecimal strings. Commit hashes and digests are evidence in
  journals, and that rule produced false positives.
- `JOURNAL_SECRETS=warn` turns denial into advice. `off` disables the check.
- The `<!-- journal-secrets-ok -->` escape exempts one line. It exists for verified false positives, and a human
  should add it, not an agent.

Keep your normal secret scanning and review gates. This project runs
[gitleaks](https://github.com/gitleaks/gitleaks) over its own full history in CI, and recommends you do the same.

## Journals are committed by default

That is deliberate — continuity that git does not carry does not reach your
teammates. It also means anything an agent writes into a journal is destined for
your history. The content contract in the generated `sessions/README.md` exists
for that reason, and `./doctor.sh` will tell you whether your journals are
tracked or local-only.

## Reporting a vulnerability

Open a [security advisory](https://github.com/dctmfoo/session-journal/security/advisories/new)
rather than a public issue. Please include the output of
`python3 .claude/hooks/session-journal.py version`, your agent runtime and
version, and a reproduction.

Report privately if you find:

- a way to make the hook execute attacker-controlled content from a journal, a
  transcript, or hook input;
- a path in the installer or the hook that writes outside the target repository
  or its state directory;
- a way to make the credential check echo a matched value;
- a way for crafted input to hang the hook, or make it block a tool call or a
  turn indefinitely.

A missed secret shape is a bug, not a vulnerability — open a normal issue with a
synthetic example. Never put a real credential in an issue.

## Supported versions

The latest release is supported. See [CHANGELOG.md](CHANGELOG.md).
