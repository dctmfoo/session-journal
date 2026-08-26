# Security policy

## What this project does to your repository

`install.sh` copies two executable shell scripts into `.claude/hooks/` and wires
them into `SessionStart` and `Stop` in your agent settings. From then on, your
agent runtime executes them automatically, on every session start and every
turn end, with your permissions. Read both scripts before you install them —
they are short and deliberately dependency-free.

The installer never fetches code. It only copies from the clone you run it
from, which is why the README tells you to clone or `degit` first.

## What the secrets guard is, and is not

The `Stop` hook scans **only the newest journal** for common credential shapes:
JWT-like values, bearer values, credential assignments, provider token prefixes,
private-key headers, and long hexadecimal strings outside digest context. It
reports line numbers and never echoes a matched value, so the hook itself cannot
leak a secret into a transcript.

It is a continuity aid, not a credential scanner:

- It scans one file, not your repository.
- It is a shape matcher. It will miss a secret that does not look like one — a
  passphrase in prose, a credential split across lines, an encoded blob.
- For `key: value` assignments it inspects the value, and deliberately exempts
  two classes so that redacting does not re-trigger the block: values shorter
  than 8 characters, and values whose first word says where the secret lives
  rather than what it is (`redacted`, `stored-…`, `see-…`, `$ENV_VAR`,
  `<anything>`). A real credential that happens to start with one of those words
  will be missed. Surrounding quotes, backticks and markdown emphasis are
  stripped before the check, so decoration does not hide a value.
- It fails open on anything it cannot parse, because a Stop hook that blocks
  forever is worse than one that misses.
- The `<!-- journal-secrets-ok -->` escape suppresses a line entirely. It exists
  for verified false positives and should be added by a human, not an agent.

Keep your normal secret scanning and review gates. This project runs
[gitleaks](https://github.com/gitleaks/gitleaks) over its own full history in
CI and recommends you do the same.

## Journals are committed by default

That is deliberate — continuity that git does not carry does not reach your
teammates. It also means anything an agent writes into a journal is destined for
your history. The content contract in the generated `sessions/README.md` exists
for that reason, and `./doctor.sh` will tell you whether your journals are
tracked or local-only.

## Reporting a vulnerability

Open a [security advisory](https://github.com/dctmfoo/session-journal/security/advisories/new)
rather than a public issue. Please include the version from your installed hook
header (`session-journal <version>`), your agent runtime and version, and a
reproduction.

Report privately if you find:

- a way to make either hook execute attacker-controlled content from a journal,
- a path in the installer that writes outside the target repository,
- a way to make the secrets guard echo a matched value,
- a way for a crafted journal to hang or infinitely block a Stop hook.

A missed secret shape is a bug, not a vulnerability — open a normal issue with a
synthetic example. Never put a real credential in an issue.

## Supported versions

The latest release is supported. See [CHANGELOG.md](CHANGELOG.md).
