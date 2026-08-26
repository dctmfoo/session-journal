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

@test "a labelled SHA-256 digest on the next line does not trigger" {
  journal="$(write_journal)"
  printf '%s\n' 'The wheel artifact hashes to' \
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "an inline git commit hash does not trigger" {
  journal="$(write_journal)"
  printf '%s\n' 'Recorded in commit 0123456789abcdef0123456789abcdef01234567 on the release branch.' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "a named token assignment triggers without echoing the value" {
  journal="$(write_journal)"
  printf '%s\n' 'Digest context nearby: sha-256 receipts are evidence.' \
    'token = definitely-secret-value' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS-GUARD"* ]]
  [[ "$output" != *"definitely-secret-value"* ]]
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

assert_secret_passes() {
  local vector="$1"
  journal="$(write_journal)"
  printf '%s\n' "$vector" >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}

@test "an angle-bracket redaction is accepted" { assert_secret_passes 'password: <redacted>'; }
@test "an annotated redaction is accepted" { assert_secret_passes 'api_key: <redacted - see the deploy vault>'; }
@test "a length-only description is accepted" { assert_secret_passes 'api_key: redacted (32 chars)'; }
@test "a location description is accepted" { assert_secret_passes 'token: stored-in-ci-secrets'; }
@test "an env-var reference is accepted" { assert_secret_passes 'api_key: $STRIPE_API_KEY'; }
@test "a short placeholder is accepted" { assert_secret_passes 'client_secret: placeholder'; }

@test "the guard names its own escape hatch when it blocks" {
  journal="$(write_journal)"
  printf '%s\n' 'token = definitely-secret-value' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"journal-secrets-ok"* ]]
}

@test "prose containing a digest keyword as a substring does not disable hex detection" {
  journal="$(write_journal)"
  printf '%s\n' 'Avoid rerunning the importer.' \
    '0123456789abcdef0123456789abcdef01234567' \
    'Android build is green.' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"SECRETS-GUARD"* ]]
}

@test "a whole-word digest keyword still exempts a receipt" {
  journal="$(write_journal)"
  printf '%s\n' 'Release tarball SHA-256:' \
    '0123456789abcdef0123456789abcdef01234567' >> "$journal"
  run bash -c "printf '%s' '{\"stop_hook_active\":false}' | '$BATS_TEST_DIRNAME/../hooks/session-journal-nudge.sh'"
  [ "$status" -eq 0 ]
}
