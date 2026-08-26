#!/usr/bin/env bats

load test_helper

setup() {
  setup_workspace
  export TARGET="$TEST_ROOT/target"
  mkdir -p "$TARGET"
  git -C "$TARGET" init -q
  git -C "$TARGET" config user.email journal@test.invalid
  git -C "$TARGET" config user.name "Journal Test"
}
teardown() { teardown_workspace; }

commit_target() {
  git -C "$TARGET" add -A >/dev/null
  git -C "$TARGET" commit -qm "${1:-adopt}"
}

@test "a healthy committed installation passes every check" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"checks passed."* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "a missing hook script is reported" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  rm -f "$TARGET/.claude/hooks/session-journal-nudge.sh"
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
  [[ "$output" == *"session-journal-nudge.sh exists"* ]]
}

@test "an uninstalled repository is reported rather than passing quietly" {
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a SessionStart hook is registered"* ]]
  [[ "$output" == *"a Stop hook is registered"* ]]
}

@test "hooks that git will never share with a teammate are reported" {
  printf '.claude/\n' > "$TARGET/.gitignore"
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"gitignored"* ]]
}

@test "an uncommitted installation is reported" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"the installation is committed"* ]]
}

@test "a journal carrying a secret is reported" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  printf '**Status:** ACTIVE\n\n## Live plan pointer\nnone\n\n## Next step for a fresh agent\nx\napi_key = sk-live-4eC39HqLyjWDarjtT1z\n' \
    > "$TARGET/sessions/2026-01-02-0304-leak.md"
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"free of secret-looking content"* ]]
  [[ "$output" != *"sk-live"* ]]
}

@test "the doctor reports which journal the pointer would deliver" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  printf '**Status:** ACTIVE\n\n## Live plan pointer\nnone\n\n## Next step for a fresh agent\nx\n' \
    > "$TARGET/sessions/2026-01-02-0304-live.md"
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [[ "$output" == *"2026-01-02-0304-live.md"* ]]
}

@test "an unmatched instruction sentinel is reported" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  commit_target
  printf '\n<!-- session-journal:begin -->\n' >> "$TARGET/CLAUDE.md"
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"balanced session-journal block"* ]]
}

@test "a nested journal directory is resolved, not truncated" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir docs/sessions >/dev/null
  commit_target
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"docs/sessions/"* ]]
  [[ "$output" != *"FAIL"* ]]
}

@test "a hook registered under the wrong event is not credited" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  jq '.hooks.PreToolUse = .hooks.Stop | .hooks.Stop = []' "$TARGET/.claude/settings.json" > "$TARGET/settings.new"
  mv "$TARGET/settings.new" "$TARGET/.claude/settings.json"
  commit_target
  run "$BATS_TEST_DIRNAME/../doctor.sh" "$TARGET"
  [ "$status" -eq 1 ]
  [[ "$output" == *"a Stop hook is registered"* ]]
}
