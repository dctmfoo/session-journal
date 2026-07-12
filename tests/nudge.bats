#!/usr/bin/env bats

load test_helper

setup() { setup_workspace; }
teardown() { teardown_workspace; }

@test "missing journal blocks once and empty input marker prevents a loop" {
  run "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No session journal exists"* ]]

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh"
  [ "$status" -eq 0 ]
}

@test "fresh journal succeeds" {
  write_journal >/dev/null
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "stale detailed journal blocks with detailed wording" {
  journal="$(write_journal)"
  make_stale "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DETAILED mode"* ]]
}

@test "stale thin journal blocks with pointer-aware wording" {
  journal="$(write_journal 2026-01-02-0304-thin.md docs/plans/work.md)"
  make_stale "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"THIN mode"* ]]
  [[ "$output" == *"docs/plans/work.md"* ]]
}

@test "missing Live plan pointer is detailed mode" {
  journal="$SESSION_JOURNAL_DIR/2026-01-02-0304-missing.md"
  printf '# journal\n**Status:** ACTIVE\n' > "$journal"
  make_stale "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DETAILED mode"* ]]
}

@test "stop_hook_active skips freshness nudge" {
  journal="$(write_journal)"
  make_stale "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":true}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "freshness override is honored" {
  journal="$(write_journal)"
  touch -t "$(date -v-2M +%Y%m%d%H%M 2>/dev/null || date -d '2 minutes ago' +%Y%m%d%H%M)" "$journal"
  run env JOURNAL_FRESH_SECS=30 "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 2 ]
}

@test "README only is treated as empty safely" {
  printf '# docs\n' > "$SESSION_JOURNAL_DIR/README.md"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"No session journal exists"* ]]
}
