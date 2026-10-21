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
  [ -x "$TARGET/.claude/hooks/session-journal.py" ]
  for event in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SessionEnd; do
    jq -e --arg e "$event" '.hooks[$e] | length == 1' "$TARGET/.claude/settings.json" >/dev/null
    jq -e --arg e "$event" '.hooks[$e][0].hooks[0].command | endswith("|| true")' "$TARGET/.claude/settings.json" >/dev/null
  done
  [ -f "$TARGET/.claude/skills/session-journal/SKILL.md" ]
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
  [ -f "$TARGET/.agents/skills/session-journal/agents/openai.yaml" ]
  jq -e '.hooks.PreToolUse[0].matcher == "Bash|apply_patch"' "$TARGET/.codex/hooks.json" >/dev/null
  jq -e '.hooks.SessionEnd[0].hooks[0].timeout <= 3' "$TARGET/.codex/hooks.json" >/dev/null
}

@test "custom sessions directory is wired through hook commands" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir docs/sessions --codex >/dev/null
  [ -f "$TARGET/docs/sessions/README.md" ]
  command="$(jq -r '.hooks.Stop[0].hooks[0].command' "$TARGET/.claude/settings.json")"
  [[ "$command" == "SESSION_JOURNAL_DIR=docs/sessions python3 "* ]]
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
  [ ! -e "$TARGET/.claude/hooks/session-journal.py" ]
  [ ! -e "$TARGET/.claude/skills/session-journal" ]
  [ ! -e "$TARGET/.agents/skills/session-journal" ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 0 ]
  [ "$(jq '.hooks.SessionEnd | length' "$TARGET/.claude/settings.json")" -eq 0 ]
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

@test "the journal template is installed so the hooks' instructions resolve" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/sessions/TEMPLATE.md" ]
  grep -Fq '## Next step for a fresh agent' "$TARGET/sessions/TEMPLATE.md"
  grep -Fq 'TEMPLATE.md' "$TARGET/sessions/README.md"
}

@test "the installed hook reports the release version" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  version="$(cat "$BATS_TEST_DIRNAME/../VERSION")"
  [ "$(python3 "$TARGET/.claude/hooks/session-journal.py" version)" = "$version" ]
}

@test "rerunning preserves the adapted sessions README" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  printf '%s\n' '- Local rule: cite the GATE-000 id.' >> "$TARGET/sessions/README.md"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  grep -Fq 'GATE-000' "$TARGET/sessions/README.md"
}

@test "rerunning preserves an adapted instruction block" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  awk '{print} /<!-- session-journal:begin -->/{print "Local rule: link the tracker id."}' \
    "$TARGET/CLAUDE.md" > "$TARGET/CLAUDE.md.new"
  mv "$TARGET/CLAUDE.md.new" "$TARGET/CLAUDE.md"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  grep -Fq 'Local rule: link the tracker id.' "$TARGET/CLAUDE.md"
  [ "$(grep -c '<!-- session-journal:begin -->' "$TARGET/CLAUDE.md")" -eq 1 ]
}

@test "rerunning preserves environment overrides on the generated commands" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  jq '.hooks.Stop[0].hooks[0].command = ("JOURNAL_NUDGE_MIN=30 " + .hooks.Stop[0].hooks[0].command)' \
    "$TARGET/.claude/settings.json" > "$TARGET/settings.new"
  mv "$TARGET/settings.new" "$TARGET/.claude/settings.json"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  jq -e '.hooks.Stop[0].hooks[0].command | startswith("JOURNAL_NUDGE_MIN=30 ")' "$TARGET/.claude/settings.json" >/dev/null
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 1 ]
}

@test "--refresh-docs regenerates what a plain rerun preserves" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  printf '%s\n' '- Local rule: cite the GATE-000 id.' >> "$TARGET/sessions/README.md"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --refresh-docs
  [ "$status" -eq 0 ]
  ! grep -Fq 'GATE-000' "$TARGET/sessions/README.md"
}

@test "--plan-pointer makes the deterministic install agree with ADOPT.md about THIN mode" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --plan-pointer docs/plans/release.md
  [ "$status" -eq 0 ]
  grep -Fq 'docs/plans/release.md' "$TARGET/sessions/README.md"
  grep -Fq 'docs/plans/release.md' "$TARGET/sessions/TEMPLATE.md"
}

@test "an unmatched sentinel refuses before anything is written" {
  printf '# Project\n\n<!-- session-journal:begin -->\nstray\n' > "$TARGET/CLAUDE.md"
  before="$(cksum < "$TARGET/CLAUDE.md")"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 65 ]
  [ ! -e "$TARGET/.claude/settings.json" ]
  [ ! -e "$TARGET/.claude/hooks/session-journal.py" ]
  [ ! -e "$TARGET/sessions/README.md" ]
  [ -z "$(find "$TARGET" -name '*.session-journal.tmp')" ]
  [ "$(cksum < "$TARGET/CLAUDE.md")" = "$before" ]
}

@test "installing into a subdirectory of a git repository is refused" {
  mkdir -p "$TARGET/nested"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET/nested"
  [ "$status" -eq 65 ]
  [[ "$output" == *"not its root"* ]]
  [ ! -e "$TARGET/nested/.claude/settings.json" ]
}

@test "a journal directory that escapes the repository is refused" {
  mkdir -p "$TEST_ROOT/outside"
  ln -s "$TEST_ROOT/outside" "$TARGET/journals"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir journals
  [ "$status" -eq 65 ]
  [ -z "$(find "$TEST_ROOT/outside" -type f)" ]
}

@test "uninstall refuses on an unmatched sentinel before removing hooks" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  printf '\n<!-- session-journal:begin -->\n' >> "$TARGET/CLAUDE.md"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --uninstall
  [ "$status" -eq 65 ]
  [ -x "$TARGET/.claude/hooks/session-journal.py" ]
  [ "$(jq '.hooks.Stop | length' "$TARGET/.claude/settings.json")" -eq 1 ]
}

@test "a plan pointer containing sed metacharacters survives substitution" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --plan-pointer 'docs/a&b.md'
  [ "$status" -eq 0 ]
  grep -Fq 'docs/a&b.md' "$TARGET/sessions/README.md"
  grep -Fq 'docs/a&b.md' "$TARGET/sessions/TEMPLATE.md"
  ! grep -Fq '{{DEFAULT_PLAN_POINTER}}' "$TARGET/sessions/README.md"
}

@test "--help is reachable without a target" {
  run "$BATS_TEST_DIRNAME/../install.sh" --help
  [ "$status" -eq 64 ]
  [[ "$output" == *"--plan-pointer"* ]]
}

@test "a rerun without --sessions-dir keeps the configured journal directory" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir docs/sessions >/dev/null
  printf 'journal\n' > "$TARGET/docs/sessions/2026-01-02-0304-real.md"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [ -f "$TARGET/docs/sessions/2026-01-02-0304-real.md" ]
  [ ! -d "$TARGET/sessions" ]
  jq -e '.hooks.Stop[0].hooks[0].command | contains("docs/sessions")' "$TARGET/.claude/settings.json" >/dev/null
}

@test "an explicit --sessions-dir still relocates on a rerun" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir docs/sessions >/dev/null
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --sessions-dir sessions
  [ "$status" -eq 0 ]
  [ -f "$TARGET/sessions/README.md" ]
}

@test "a quoted environment override survives a rerun" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  jq '.hooks.Stop[0].hooks[0].command = ("JOURNAL_NUDGE_MIN=\"30\" " + .hooks.Stop[0].hooks[0].command)' \
    "$TARGET/.claude/settings.json" > "$TARGET/settings.new"
  mv "$TARGET/settings.new" "$TARGET/.claude/settings.json"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  jq -e '.hooks.Stop[0].hooks[0].command | startswith("JOURNAL_NUDGE_MIN=\"30\" ")' "$TARGET/.claude/settings.json" >/dev/null
}

@test "a command registered under another event cannot contribute to the generated one" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  jq '.hooks.PreToolUse = [{hooks:[{type:"command",command:"AUDIT=x session-journal-nudge.sh"}]}]' \
    "$TARGET/.claude/settings.json" > "$TARGET/settings.new"
  mv "$TARGET/settings.new" "$TARGET/.claude/settings.json"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  jq -e '.hooks.Stop[0].hooks[0].command | contains("AUDIT=") | not' "$TARGET/.claude/settings.json" >/dev/null
}

@test "a newline in --plan-pointer is refused before anything is written" {
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --plan-pointer "$(printf 'a\nb')"
  [ "$status" -eq 64 ]
  [ ! -e "$TARGET/.claude/settings.json" ]
  [ ! -e "$TARGET/sessions/README.md" ]
}

@test "uninstall refuses on an unmatched AGENTS.md sentinel without Codex flags" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex >/dev/null
  printf '\n<!-- session-journal:begin -->\n' >> "$TARGET/AGENTS.md"
  before="$(cksum < "$TARGET/AGENTS.md")"
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --uninstall
  [ "$status" -eq 65 ]
  [ "$(cksum < "$TARGET/AGENTS.md")" = "$before" ]
  [ -x "$TARGET/.claude/hooks/session-journal.py" ]
}

@test "uninstall does not leave behind instruction files it created" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex >/dev/null
  [ -f "$TARGET/CLAUDE.md" ]
  [ -f "$TARGET/AGENTS.md" ]
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$TARGET/CLAUDE.md" ]
  [ ! -e "$TARGET/AGENTS.md" ]
}

@test "uninstall preserves an instruction file that had other content" {
  printf '# Project rules\n\nBe careful.\n' > "$TARGET/CLAUDE.md"
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --uninstall
  [ "$status" -eq 0 ]
  [ -f "$TARGET/CLAUDE.md" ]
  grep -Fq 'Be careful.' "$TARGET/CLAUDE.md"
  ! grep -Fq 'session-journal:begin' "$TARGET/CLAUDE.md"
}

@test "an install migrates a v1 installation in place" {
  mkdir -p "$TARGET/.claude/hooks" "$TARGET/docs/sessions"
  printf '#!/bin/bash\n' > "$TARGET/.claude/hooks/session-journal-pointer.sh"
  printf '#!/bin/bash\n' > "$TARGET/.claude/hooks/session-journal-nudge.sh"
  printf 'journal\n' > "$TARGET/docs/sessions/2026-01-02-0304-old.md"
  cat > "$TARGET/.claude/settings.json" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"*","hooks":[{"type":"command","command":"SESSION_JOURNAL_DIR=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)/docs/sessions\" \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/hooks/session-journal-pointer.sh\""}]}],
 "Stop":[{"hooks":[{"type":"command","command":"./mine.sh"},{"type":"command","command":"JOURNAL_FRESH_SECS=900 SESSION_JOURNAL_DIR=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)/docs/sessions\" \"$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.claude/hooks/session-journal-nudge.sh\""}]}]}}
JSON
  run "$BATS_TEST_DIRNAME/../install.sh" "$TARGET"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reusing the journal directory already configured here: docs/sessions/"* ]]
  [ ! -e "$TARGET/.claude/hooks/session-journal-pointer.sh" ]
  [ ! -e "$TARGET/.claude/hooks/session-journal-nudge.sh" ]
  ! grep -Eq 'session-journal-(pointer|nudge)' "$TARGET/.claude/settings.json"
  ! grep -q 'JOURNAL_FRESH_SECS' "$TARGET/.claude/settings.json"
  jq -e '.hooks.Stop[] | select(.hooks[].command == "./mine.sh")' "$TARGET/.claude/settings.json" >/dev/null
  jq -e '.hooks.Stop[-1].hooks[0].command | startswith("SESSION_JOURNAL_DIR=docs/sessions python3")' "$TARGET/.claude/settings.json" >/dev/null
  [ -f "$TARGET/docs/sessions/2026-01-02-0304-old.md" ]
  [ ! -d "$TARGET/sessions" ]
}

@test "--no-skill installs hooks without the agent skill" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" --codex --no-skill >/dev/null
  [ ! -e "$TARGET/.claude/skills/session-journal" ]
  [ ! -e "$TARGET/.agents/skills/session-journal" ]
  [ -x "$TARGET/.claude/hooks/session-journal.py" ]
}

@test "the installed hooks run end to end in the target" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  command="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$TARGET/.claude/settings.json")"
  out="$(cd "$TARGET" && printf '{"session_id":"s1","source":"startup"}' | CLAUDE_PROJECT_DIR="$TARGET" sh -c "$command")"
  printf '%s' "$out" | jq -e '.hookSpecificOutput.additionalContext | contains("TEMPLATE.md")' >/dev/null
  stop="$(jq -r '.hooks.Stop[0].hooks[0].command' "$TARGET/.claude/settings.json")"
  out="$(cd "$TARGET" && printf '{"session_id":"s1","stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$TARGET" sh -c "$stop")"
  [ "$out" = "{}" ]
  [ "$(cat "$TARGET/.claude/state/session-journal/.gitignore")" = "*" ]
}

@test "a missing script never blocks the agent" {
  "$BATS_TEST_DIRNAME/../install.sh" "$TARGET" >/dev/null
  rm -f "$TARGET/.claude/hooks/session-journal.py"
  stop="$(jq -r '.hooks.Stop[0].hooks[0].command' "$TARGET/.claude/settings.json")"
  run sh -c "cd '$TARGET' && printf '{}' | $stop"
  [ "$status" -eq 0 ]
}
