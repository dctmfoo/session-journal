# Optional spine-promotion nudge

Install this extra Stop hook only in long-running repositories where DETAILED journals repeatedly accumulate. At six milestones by default, it asks the agent to promote recurring work into a durable plan or specification and flip the journal to THIN.

Configuration:

- `SPINE_PROMOTION_THRESHOLD` — milestone count, default `6`.
- `SPINE_PROMOTION_TARGET_HINT` — suggested durable-doc directory, default `docs/plans/`.

Merge it as an additional Stop handler; do not replace the freshness and secrets hook. A repository can also build a reverse index from file paths to journals for a local documentation site, but that site-specific index is intentionally outside this portable module.
