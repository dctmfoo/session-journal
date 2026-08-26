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

@test "pretty-printed hook JSON still honours stop_hook_active" {
  journal="$(write_journal)"
  make_stale "$journal"
  run bash -c "printf '{\n  \"stop_hook_active\": true\n}\n' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "an expired one-shot marker does not swallow a later session's nudge" {
  journal="$(write_journal)"
  make_stale "$journal"
  marker_dir="${TMPDIR:-/tmp}/session-journal-nudge-$(printf '%s' "$TEST_ROOT" | cksum | awk '{print $1}').d"

  run "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh"
  [ "$status" -eq 2 ]
  [ -d "$marker_dir" ]

  touch -t 202001010000 "$marker_dir"
  run "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh"
  [ "$status" -eq 2 ]
}

@test "SESSION_JOURNAL_SKIP suppresses the freshness nudge" {
  journal="$(write_journal)"
  make_stale "$journal"
  run env SESSION_JOURNAL_SKIP=1 "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
}

@test "SESSION_JOURNAL_SKIP does not suppress the secrets guard" {
  journal="$(write_journal)"
  printf '%s\n' 'token = definitely-secret-value' >> "$journal"
  run env SESSION_JOURNAL_SKIP=1 "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS-GUARD"* ]]
}

@test "a non-numeric freshness window falls back to the default" {
  journal="$(write_journal)"
  make_stale "$journal"
  run env JOURNAL_FRESH_SECS=5m "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a whole number of seconds"* ]]
}

@test "identical mtimes select the later filename for the freshness check" {
  thin="$(write_journal 2026-01-02-0304-alpha.md docs/plans/work.md 'ACTIVE - alpha')"
  detailed="$(write_journal 2026-08-20-1500-charlie.md none 'ACTIVE - charlie')"
  tie_mtimes "$thin" "$detailed"
  touch -t 202001010000 "$thin" "$detailed"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"DETAILED mode"* ]]
}

@test "the nudge never creates the sessions directory" {
  rmdir "$SESSION_JOURNAL_DIR"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [ ! -d "$SESSION_JOURNAL_DIR" ]
}

# The gate can only assert what git can prove: the journal has uncommitted
# content changes, or it rode along in the most recent commit. A journal that did
# neither, while tracked work piled up, has not recorded that work -- and a bare
# `touch` must not be able to claim otherwise.
@test "a touched but unchanged journal does not satisfy the gate when other work happened" {
  setup_git_workspace
  journal="$(write_journal)"
  commit_workspace "baseline"
  printf 'v2\n' > "$TEST_ROOT/src/app.txt"
  commit_workspace "work without touching the journal"
  printf 'v3\n' > "$TEST_ROOT/src/app.txt"
  touch "$journal"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not record the tracked changes"* ]]
}

@test "a genuinely edited journal satisfies the gate" {
  setup_git_workspace
  journal="$(write_journal)"
  commit_workspace "baseline"
  printf 'v2\n' > "$TEST_ROOT/src/app.txt"
  printf -- '- recorded the change\n' >> "$journal"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "a clean work tree needs no journal movement" {
  setup_git_workspace
  write_journal >/dev/null
  commit_workspace "baseline"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "JOURNAL_REQUIRE_CONTENT_CHANGE=0 restores mtime-only freshness" {
  setup_git_workspace
  journal="$(write_journal)"
  commit_workspace "baseline"
  printf 'v2\n' > "$TEST_ROOT/src/app.txt"
  touch "$journal"

  run env JOURNAL_REQUIRE_CONTENT_CHANGE=0 "$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh" <<< '{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
}

@test "a gitignored journal falls back to mtime-only freshness" {
  setup_git_workspace
  journal="$(write_journal)"
  printf 'sessions/\n' > "$TEST_ROOT/.gitignore"
  commit_workspace "baseline"
  printf 'v2\n' > "$TEST_ROOT/src/app.txt"
  touch "$journal"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "a journal committed alongside the work is not treated as unmoved" {
  setup_git_workspace
  journal="$(write_journal)"
  commit_workspace "baseline"
  printf 'v2\n' > "$TEST_ROOT/src/app.txt"
  printf -- '- recorded the change\n' >> "$journal"
  commit_workspace "work and journal together"
  printf 'v3\n' > "$TEST_ROOT/src/app.txt"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "untracked scratch files are not work the journal owes an entry for" {
  setup_git_workspace
  write_journal >/dev/null
  commit_workspace "baseline"
  printf 'junk' > "$TEST_ROOT/.DS_Store"

  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "a slow or oversized stdin payload cannot stall the hook" {
  journal="$(write_journal)"
  make_stale "$journal"
  start="$(date +%s)"
  run bash -c "{ printf '{\n'; i=0; while [ \$i -lt 5000 ]; do printf '  \"pad%s\": 1,\n' \"\$i\"; i=\$((i+1)); done; printf '  \"stop_hook_active\": false\n}\n'; } | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  elapsed=$(( $(date +%s) - start ))
  [ "$status" -eq 2 ]
  [ "$elapsed" -lt 15 ]
}
