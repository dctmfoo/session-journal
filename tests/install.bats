#!/usr/bin/env bats

load test_helper

setup() {
  setup_workspace
  export TARGET="$TEST_ROOT/target"
  mkdir -p "$TARGET"
  git -C "$TARGET" init -q
}
teardown() { teardown_workspace; }

@test "fresh install creates Claude wiring, docs, and executable shared hooks" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -x "$TARGET/.claude/hooks/session-journal-pointer.sh" ]
  [ -x "$TARGET/.claude/hooks/session-journal-nudge.sh" ]
  jq -e '.hooks.SessionStart | length == 1' "$TARGET/.claude/settings.json" >/dev/null
  [ -f "$TARGET/sessions/README.md" ]
  [ -f "$TARGET/CLAUDE.md" ]
  grep -Fq "Timestamp label: \`$(date +%Z)\`" "$TARGET/sessions/README.md"
}

@test "rerun is idempotent" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  [ "$(grep -c '<!-- session-journal:begin -->' "$TARGET/CLAUDE.md")" -eq 1 ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 1 ]
}

@test "existing hooks are preserved while owned hooks merge once" {
  mkdir -p "$TARGET/.claude"
  printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"./start.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"./existing.sh"}]}]}}' > "$TARGET/.claude/settings.json"
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 2 ]
  jq -e '.hooks.Stop[] | select(.hooks[].command == "./existing.sh")' "$TARGET/.claude/settings.json" >/dev/null
  jq -e '.hooks.SessionStart[] | select(.hooks[].command == "./start.sh")' "$TARGET/.claude/settings.json" >/dev/null
}

@test "codex option creates valid project hook wiring and AGENTS instructions" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex
  [ "$status" -eq 0 ]
  jq -e '.hooks.SessionStart | length == 1' "$TARGET/.codex/hooks.json" >/dev/null
  [[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TARGET/.codex/hooks.json")" == *'git rev-parse --show-toplevel'* ]]
  [ -f "$TARGET/AGENTS.md" ]
}

@test "custom sessions directory is wired through hook commands" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir docs/sessions --codex >/dev/null
  [ -f "$TARGET/docs/sessions/README.md" ]
  command="$(jq -r '.hooks.Stop[0].hooks[0].command' "$TARGET/.claude/settings.json")"
  [[ "$command" == SESSION_JOURNAL_DIR=* ]]
  [[ "$command" == *'$(git rev-parse --show-toplevel 2>/dev/null || pwd)/docs/sessions'* ]]
  [[ "$command" != *"$TARGET"* ]]
}

@test "Codex-only install skips Claude settings and instructions" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --no-claude >/dev/null
  [ ! -e "$TARGET/.claude/settings.json" ]
  [ ! -e "$TARGET/CLAUDE.md" ]
  [ -e "$TARGET/.codex/hooks.json" ]
  [ -e "$TARGET/AGENTS.md" ]
}

@test "invalid JSON is refused without changing it" {
  mkdir -p "$TARGET/.claude"
  printf '%s\n' '{ // JSON5' > "$TARGET/.claude/settings.json"
  before="$(cksum "$TARGET/.claude/settings.json")"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 65 ]
  [ "$(cksum "$TARGET/.claude/settings.json")" = "$before" ]
}

@test "unsafe sessions paths are rejected without writing outside the target" {
  for path in .. ../escape /tmp/escape ./escape 'docs/../escape' 'bad;touch-pwned'; do
    run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir "$path"
    [ "$status" -eq 64 ]
  done
  [ ! -e "$TEST_ROOT/README.md" ]
}

@test "unmatched instruction sentinels are refused without truncation" {
  printf '%s\n' '# keep' '<!-- session-journal:begin -->' 'important tail' > "$TARGET/CLAUDE.md"
  before="$(cksum "$TARGET/CLAUDE.md")"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 65 ]
  [ "$(cksum "$TARGET/CLAUDE.md")" = "$before" ]
}

@test "uninstall removes owned wiring and blocks but keeps journals" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex >/dev/null
  printf '# history\n' > "$TARGET/sessions/2026-01-02-0304-history.md"
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --uninstall >/dev/null
  [ ! -e "$TARGET/.claude/hooks/session-journal-pointer.sh" ]
  [ ! -e "$TARGET/.claude/hooks/session-journal-nudge.sh" ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 0 ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.codex/hooks.json")" -eq 0 ]
  ! grep -q '<!-- session-journal:begin -->' "$TARGET/CLAUDE.md"
  [ -f "$TARGET/sessions/2026-01-02-0304-history.md" ]
}

@test "uninstall is safe before install and on repeated runs" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --uninstall
  [ "$status" -eq 0 ]
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex >/dev/null
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --uninstall >/dev/null
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --uninstall
  [ "$status" -eq 0 ]
}
