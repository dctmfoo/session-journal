#!/usr/bin/env bats

load test_helper

setup() { setup_workspace; }
teardown() { teardown_workspace; }

@test "empty sessions emits valid create instruction JSON" {
  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  [[ "$output" == *"No session journal exists"* ]]
}

@test "newest journal is selected and status plus complete next step are extracted" {
  older="$(write_journal 2026-01-02-0304-older.md none 'DONE - old')"
  sleep 1
  newer="$(write_journal 2026-01-02-0305-newer.md docs/plans/work.md 'ACTIVE - new')"
  touch "$older" "$newer"
  touch -t 202001010000 "$older"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [[ "$output" == *"2026-01-02-0305-newer.md"* ]]
  [[ "$output" == *"ACTIVE - new"* ]]
  [[ "$output" == *"Run the next focused test."* ]]
  [[ "$output" == *'Preserve quoted text: \"ready\".'* ]]
}

@test "README is excluded and missing fields are handled" {
  printf '# sessions docs\n' > "$SESSION_JOURNAL_DIR/README.md"
  printf '# Minimal journal\n' > "$SESSION_JOURNAL_DIR/2026-01-02-0304-minimal.md"
  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [[ "$output" == *"Status not recorded"* ]]
  [[ "$output" == *"Next step not recorded"* ]]
}
