# Session: investigate intermittent cache misses

**Started:** 2026-02-11 14:05 UTC
**Last updated:** 2026-02-11 15:20 UTC
**Status:** ACTIVE — cause isolated; regression check not written

## User intent
Find why a small local tool occasionally misses a cached result.

## Live plan pointer
none

## Milestones
- 2026-02-11 14:30 — reproduced when two processes initialize the cache together.
- 2026-02-11 15:05 — isolated a non-atomic temporary filename collision.

## Decisions and constraints
- Keep this DETAILED until the regression check proves the cause.

## Verification evidence
- A two-process loop reproduced the miss in 7 of 100 attempts before the candidate fix and 0 of 500 after it.

## Commits made
- none

## Files touched
- `src/cache.ts` — candidate unique temporary name.

## Where we are now
The cause is supported by a repeatable local check. The candidate change is uncommitted and still needs a focused regression check.

## Next step for a fresh agent
Add the concurrent-initialization regression check in `tests/cache.test.ts`, confirm it fails without the candidate change, then rerun it with the change.

## Open questions / loose ends
- Does the Windows rename path have the same atomicity contract?

## Change log
- 2026-02-11 14:05 — journal created.
- 2026-02-11 15:20 — cause isolated and next proof recorded.
