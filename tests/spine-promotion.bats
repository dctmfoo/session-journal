#!/usr/bin/env bats

load test_helper

setup() {
  setup_workspace
  export SPINE="$BATS_TEST_DIRNAME/../extras/spine-promotion/journal-spine-promotion-nudge.sh"
}
teardown() { teardown_workspace; }

add_milestones() {
  local journal=$1 count=$2 tmp="$journal.tmp"
  awk -v count="$count" '
    /^## Milestones$/ {
      print
      for (i = 1; i <= count; i++) print "- Synthetic milestone " i "."
      skipping=1
      next
    }
    skipping && /^## / { skipping=0 }
    !skipping { print }
  ' "$journal" > "$tmp"
  mv "$tmp" "$journal"
}

@test "no journal succeeds" {
  run "$SPINE"
  [ "$status" -eq 0 ]
}

@test "THIN journal skips promotion at the threshold" {
  journal="$(write_journal 2026-01-02-0304-thin.md docs/plans/work.md)"
  add_milestones "$journal" 6
  run "$SPINE"
  [ "$status" -eq 0 ]
}

@test "DETAILED journal below threshold succeeds" {
  journal="$(write_journal)"
  add_milestones "$journal" 5
  run "$SPINE"
  [ "$status" -eq 0 ]
}

@test "DETAILED journal at threshold blocks with default hint" {
  journal="$(write_journal)"
  add_milestones "$journal" 6
  run "$SPINE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"docs/plans/"* ]]
}

@test "threshold and target hint overrides are honored" {
  journal="$(write_journal)"
  add_milestones "$journal" 2
  run env SPINE_PROMOTION_THRESHOLD=2 SPINE_PROMOTION_TARGET_HINT=specs/ "$SPINE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"specs/"* ]]
}
