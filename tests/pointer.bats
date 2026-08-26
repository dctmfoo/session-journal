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

@test "identical mtimes fall back to the filename instead of keeping the oldest" {
  older="$(write_journal 2026-01-02-0304-alpha.md none 'ACTIVE - alpha')"
  newer="$(write_journal 2026-08-20-1500-charlie.md none 'ACTIVE - charlie')"
  tie_mtimes "$older" "$newer"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-08-20-1500-charlie.md"* ]]
  [[ "$output" != *"2026-01-02-0304-alpha.md"* ]]
}

@test "mtime still outranks the filename so an appended journal stays live" {
  newer_name="$(write_journal 2026-08-20-1500-charlie.md none 'ACTIVE - charlie')"
  sleep 1
  older_name="$(write_journal 2026-01-02-0304-alpha.md none 'ACTIVE - alpha')"
  touch "$older_name"
  touch -t 202001010000 "$newer_name"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-01-02-0304-alpha.md"* ]]
}

@test "a DONE newest journal yields to an older journal still open for work" {
  live="$(write_journal 2026-01-02-0304-live.md none 'ACTIVE - still working')"
  sleep 1
  done_journal="$(write_journal 2026-01-02-0305-done.md none 'DONE - shipped')"
  touch "$done_journal"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [[ "$output" == *"Live session journal"* ]]
  [[ "$output" == *"2026-01-02-0304-live.md"* ]]
  [[ "$output" == *"2026-01-02-0305-done.md"* ]]
  [ -n "$live" ]
}

@test "a BLOCKED journal counts as open work" {
  write_journal 2026-01-02-0304-blocked.md none 'BLOCKED - waiting on review' >/dev/null
  sleep 1
  done_journal="$(write_journal 2026-01-02-0305-done.md none 'DONE - shipped')"
  touch "$done_journal"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2026-01-02-0304-blocked.md"* ]]
}

@test "when every journal is DONE the pointer says so instead of replaying its next step" {
  write_journal 2026-01-02-0304-done.md none 'DONE - shipped' >/dev/null

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [[ "$output" == *"finished session"* ]]
  [[ "$output" == *"treat this session as new work"* ]]
  [[ "$output" != *"Next step for a fresh agent:"* ]]
}

@test "a title-cased next-step heading still delivers the section" {
  journal="$SESSION_JOURNAL_DIR/2026-01-02-0304-drift.md"
  printf '**Status:** ACTIVE - drifting\n\n## Live plan pointer\nnone\n\n## Next Step For A Fresh Agent\nRun the drifted command.\n' > "$journal"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run the drifted command."* ]]
  [[ "$output" != *"Next step not recorded"* ]]
}

@test "TEMPLATE.md is not mistaken for a journal" {
  printf '# Session: <intent>\n\n**Status:** ACTIVE | DONE | BLOCKED\n' > "$SESSION_JOURNAL_DIR/TEMPLATE.md"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No session journal exists"* ]]
}

@test "the pointer never creates the sessions directory" {
  rmdir "$SESSION_JOURNAL_DIR"
  run "$BATS_TEST_DIRNAME/../hooks/session-journal-pointer.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e . >/dev/null
  [ ! -d "$SESSION_JOURNAL_DIR" ]
}
