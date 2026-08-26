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

@test "every environment variable the hooks read is documented" {
  for name in JOURNAL_FRESH_SECS SESSION_JOURNAL_DIR SESSION_JOURNAL_SKIP \
              JOURNAL_REQUIRE_CONTENT_CHANGE JOURNAL_STOP_MARKER_TTL_SECS; do
    grep -Fq "$name" "$(repo)/README.md" || {
      echo "$name is read by a hook but never documented in README.md"
      return 1
    }
  done
}

@test "every installer flag is documented in the README" {
  for flag in --sessions-dir --plan-pointer --codex --no-claude --refresh-docs --uninstall; do
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

@test "the spec and the pointer hook agree that DONE is not the live frontier" {
  grep -Fq 'DONE' "$(repo)/spec/session-journal-spec.md"
  grep -Fq 'ACTIVE|BLOCKED' "$(repo)/hooks/session-journal-pointer.sh"
}
