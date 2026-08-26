setup_workspace() {
  export TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-journal-test.XXXXXX")"
  export CLAUDE_PROJECT_DIR="$TEST_ROOT"
  export SESSION_JOURNAL_DIR="$TEST_ROOT/sessions"
  mkdir -p "$SESSION_JOURNAL_DIR"
}

teardown_workspace() {
  rm -rf "$TEST_ROOT"
}

write_journal() {
  local path="$SESSION_JOURNAL_DIR/${1:-2026-01-02-0304-test.md}"
  local pointer="${2:-none}"
  local status="${3:-ACTIVE — testing}"
  mkdir -p "$SESSION_JOURNAL_DIR"
  printf '# Session: synthetic test\n\n**Started:** 2026-01-02 03:04 UTC\n**Last updated:** 2026-01-02 03:04 UTC\n**Status:** %s\n\n## User intent\nTest the journal hooks.\n\n## Live plan pointer\n%s\n\n## Milestones\n- Hook fixture created.\n\n## Commits made\n- none\n\n## Files touched\n- none\n\n## Where we are now\nSynthetic fixture is ready.\n\n## Next step for a fresh agent\nRun the next focused test.\nPreserve quoted text: "ready".\n\n## Open questions / loose ends\n- none\n\n## Change log\n- created\n' "$status" "$pointer" > "$path"
  printf '%s\n' "$path"
}

make_stale() {
  local path="$1"
  touch -t 202001010000 "$path"
}

# A workspace that is a real git work tree, for the content-change gate.
setup_git_workspace() {
  setup_workspace
  git -C "$TEST_ROOT" init -q
  git -C "$TEST_ROOT" config user.email journal@test.invalid
  git -C "$TEST_ROOT" config user.name "Journal Test"
  mkdir -p "$TEST_ROOT/src"
  printf 'v1\n' > "$TEST_ROOT/src/app.txt"
}

commit_workspace() {
  git -C "$TEST_ROOT" add -A >/dev/null
  git -C "$TEST_ROOT" commit -qm "${1:-checkpoint}"
}

# Give every journal the same whole-second mtime, the way a checkout does.
tie_mtimes() {
  touch -t 202601020304 "$@"
}
