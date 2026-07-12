# An adopted repository

An agent-led installation might leave this small footprint:

```text
project/
├── .claude/
│   ├── hooks/
│   │   ├── session-journal-pointer.sh
│   │   └── session-journal-nudge.sh
│   └── settings.json
├── .codex/
│   └── hooks.json
├── sessions/
│   ├── README.md
│   └── 2026-03-04-1015-adopt-session-journal.md
├── AGENTS.md
└── CLAUDE.md
```

Both runtimes reference the same scripts. Existing hook groups remain beside the installed groups. The local `sessions/README.md` says which docs are normal THIN pointers, which timezone label to use, and which evidence identifiers matter in this repository.

On a fresh start, the pointer hook injects only the newest path, one-line status, and complete next step. On stop, a fresh journal exits cleanly; a stale journal gets one mode-aware continuation; secret-looking content remains blocking even after that continuation.
