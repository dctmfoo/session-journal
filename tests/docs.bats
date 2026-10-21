#!/usr/bin/env bats

# Documentation drift is a product problem here, not a cosmetic one: a journal
# is the highest-trust artifact a fresh agent reads, and this repository has
# already shipped a wrong test count that propagated from a journal into
# docs/verification.md because the next agent believed it. These checks hold the
# prose to the code.

repo() { printf '%s' "$BATS_TEST_DIRNAME/.."; }

@test "the verification record's bats count matches the suite" {
  claimed="$(sed -n 's|.*<!-- bats-count -->\([0-9]*\)<!-- /bats-count -->.*|\1|p' "$(repo)/docs/verification.md")"
  [ -n "$claimed" ]
  actual="$(grep -ch '^@test' "$(repo)"/tests/*.bats | awk '{n+=$1} END{print n}')"
  [ "$claimed" -eq "$actual" ]
}

@test "the changelog documents the current VERSION" {
  version="$(cat "$(repo)/VERSION")"
  [ -n "$version" ]
  grep -Fq "## $version" "$(repo)/CHANGELOG.md"
}

@test "the verification record's unittest count matches the suite" {
  claimed="$(sed -n 's|.*<!-- unittest-count -->\([0-9]*\)<!-- /unittest-count -->.*|\1|p' "$(repo)/docs/verification.md")"
  [ -n "$claimed" ]
  actual="$(grep -c '^    def test_' "$(repo)/tests/test_journal.py")"
  [ "$claimed" -eq "$actual" ]
}

@test "every environment variable the hook reads is documented" {
  names="$(grep -oE "environ\.get\('[A-Z_]+'|env_float\('[A-Z_]+'" "$(repo)/hooks/session-journal.py" \
    | grep -oE "'[A-Z_]+'" | tr -d "'" | sort -u)"
  [ -n "$names" ]
  for name in $names; do
    case "$name" in CLAUDE_*|CODEX_*) continue ;; esac
    grep -Fq "$name" "$(repo)/README.md" || {
      echo "$name is read by the hook but never documented in README.md"
      return 1
    }
  done
}

@test "the script reports the release VERSION" {
  [ "$(python3 "$(repo)/hooks/session-journal.py" version)" = "$(cat "$(repo)/VERSION")" ]
}

@test "the Codex skill mirrors the Claude skill and carries openai.yaml" {
  cmp "$(repo)/skills/session-journal/SKILL.md" "$(repo)/codex/skills/session-journal/SKILL.md"
  grep -q '^interface:' "$(repo)/codex/skills/session-journal/agents/openai.yaml"
  grep -q '^name: session-journal$' "$(repo)/skills/session-journal/SKILL.md"
  grep -q '^description: ' "$(repo)/skills/session-journal/SKILL.md"
}

@test "ADOPT.md routes the adopting agent through the skill" {
  grep -Fq 'skills/session-journal/SKILL.md' "$(repo)/ADOPT.md"
}

@test "the hook snippets match what the installer generates" {
  target="$(mktemp -d "${TMPDIR:-/tmp}/sj-snippet.XXXXXX")"
  git -C "$target" init -q
  "$(repo)/install.sh" "$target" --codex --no-skill >/dev/null
  diff <(jq -S '{hooks}' "$target/.claude/settings.json") <(jq -S . "$(repo)/hooks/claude-settings.snippet.json")
  diff <(jq -S '{hooks}' "$target/.codex/hooks.json") <(jq -S . "$(repo)/hooks/codex-hooks.snippet.json")
  rm -rf "${target:?}"
}

@test "every installer flag is documented in the README" {
  for flag in --sessions-dir --plan-pointer --codex --no-claude --no-skill --refresh-docs --uninstall; do
    grep -Fq -- "$flag" "$(repo)/README.md" || {
      echo "$flag is accepted by install.sh but never documented in README.md"
      return 1
    }
  done
}

@test "the shipped template carries the mandatory next-step section" {
  grep -Fq '## Next step for a fresh agent' "$(repo)/templates/session-journal.md"
  grep -Fq '## Live plan pointer' "$(repo)/templates/session-journal.md"
}

@test "the spec and the hook agree on the closed statuses" {
  for status in DONE COMPLETE COMPLETED DELIVERED CLOSED SUPERSEDED ABANDONED; do
    grep -Fq "'$status'" "$(repo)/hooks/session-journal.py"
    grep -Fq "\`$status\`" "$(repo)/spec/session-journal-spec.md"
  done
}
