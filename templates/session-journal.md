# Session: <intent in one line>

**Started:** YYYY-MM-DD HH:MM {{TIMEZONE}}
**Last updated:** YYYY-MM-DD HH:MM {{TIMEZONE}}
**Status:** ACTIVE | DONE | BLOCKED — one current-state line

## User intent
<What the user asked for, quoted when short.>

## Live plan pointer
{{DEFAULT_PLAN_POINTER}}

## Milestones
- YYYY-MM-DD HH:MM — <one-line outcome and evidence pointer>

## Decisions and constraints
- <Decision, constraint, and brief reason.>

## Verification evidence
<Prefer evidence a reader can re-run over a number frozen at write time: name
the command, the test, the CI run, or the artifact. "bats tests — see CI run
<url>" stays true; "38 of 38 passed" silently rots the moment the suite grows,
and the next agent will believe it.>
- <Command or check> — <observed result, and where to re-observe it>

## Commits made
- <hash> <subject>, or `none`

## Files touched
- `path` — <why>

## Where we are now
<Two to four present-tense lines.>

## Next step for a fresh agent
<One concrete action: command, file, or decision. This section is mandatory and
is injected verbatim at the start of the next session — write it for someone who
has read nothing else.>

## Open questions / loose ends
- <Question or `none`.>

## Change log
- YYYY-MM-DD HH:MM — journal created
