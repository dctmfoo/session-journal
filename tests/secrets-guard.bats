#!/usr/bin/env bats

load test_helper

setup() { setup_workspace; }
teardown() { teardown_workspace; }

assert_secret_blocks() {
  local vector="$1"
  journal="$(write_journal)"
  printf '%s\n' "$vector" >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS-GUARD"* ]]
}

@test "JWT-like content triggers" { assert_secret_blocks "$(printf '%s%s' 'ey' 'Jabcdefghijklmnopqrstuvwxyz0123456789')"; }
@test "Bearer token triggers" { assert_secret_blocks 'Bearer abcdefghijklmnopQRSTUV'; }
@test "credential assignment triggers" { assert_secret_blocks 'password = hunter2secret'; }
@test "passphrase assignment triggers" { assert_secret_blocks 'passphrase: correct-horse-battery'; }
@test "long hex triggers" { assert_secret_blocks '0123456789abcdef0123456789abcdef01234567'; }
@test "uppercase credential assignment triggers" { assert_secret_blocks 'PASSWORD = synthetic-secret-value'; }
@test "provider-shaped token triggers" { assert_secret_blocks 'AKIAIOSFODNN7EXAMPLE'; }

@test "truncated ids and key names alone do not trigger" {
  journal="$(write_journal)"
  printf '%s\n' '6750bd6e…' 'password' 'api_key:' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "a verified full commit hash can use the line-scoped allowlist" {
  journal="$(write_journal)"
  printf '%s\n' '0123456789abcdef0123456789abcdef01234567 <!-- journal-secrets-ok -->' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "allowlist comment suppresses only its line" {
  journal="$(write_journal)"
  printf '%s\n' 'password = syntheticvalue <!-- journal-secrets-ok -->' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "guard still blocks when stop_hook_active is true" {
  journal="$(write_journal)"
  printf '%s\n' 'token = definitely-secret-value' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":true}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS-GUARD"* ]]
}
