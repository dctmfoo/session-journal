# An adopted repository

An agent-led installation might leave this small footprint:

```text
project/
├── .claude/
│   ├── hooks/
│   │   └── session-journal.py
│   ├── skills/session-journal/SKILL.md
│   ├── state/session-journal/      (local only; ignores itself)
│   └── settings.json
├── .agents/
│   └── skills/session-journal/     (Codex mirror, with agents/openai.yaml)
├── .codex/
│   └── hooks.json
├── sessions/
│   ├── README.md
│   └── 2026-03-04-1015-adopt-session-journal.md
├── AGENTS.md
└── CLAUDE.md
```

Both runtimes run the same script. Existing hook groups remain beside the installed groups. The local `sessions/README.md` says which docs are normal THIN pointers, which timezone label to use, and which evidence identifiers matter in this repository.

What happens when sessions run:

- **New session.** The hook lists up to five open candidate journals, each with its status and next step. Journals
  another live session owns are marked IN USE.
- **Resumed or compacted session.** The hook names the journal the session is bound to.
- **A turn that only read.** It ends quietly.
- **A turn that landed a commit without touching its own journal.** It gets one mode-aware request to update that
  journal. Neither another session's journal nor a newer file affects this.
- **A credential-shaped journal write.** It is denied before it reaches disk.
