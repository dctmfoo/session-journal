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
}

@test "rerun is idempotent" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  [ "$(grep -c '<!-- session-journal:begin -->' "$TARGET/CLAUDE.md")" -eq 1 ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 1 ]
}

@test "existing hooks are preserved while owned hooks merge once" {
  mkdir -p "$TARGET/.claude"
  printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"./existing.sh"}]}]}}' > "$TARGET/.claude/settings.json"
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 2 ]
  jq -e '.hooks.Stop[] | select(.hooks[].command == "./existing.sh")' "$TARGET/.claude/settings.json" >/dev/null
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
  [[ "$(jq -r '.hooks.Stop[0].hooks[0].command' "$TARGET/.claude/settings.json")" == SESSION_JOURNAL_DIR=* ]]
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
