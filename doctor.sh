#!/bin/bash
# Re-runnable self-check for an adopted session-journal installation.
#
# ADOPT.md Phase C is a verification matrix the installing agent runs once, at
# adoption time, and then nobody can run again. Hooks that stop firing are
# silent by construction: a SessionStart hook that never runs looks exactly like
# a session with no journal, and a Stop hook that never runs looks exactly like
# a journal that is always fresh. This script turns that one-time ritual into
# something a teammate, a CI job, or a suspicious agent can run at any time.
#
# Exit 0 when every check passes, 1 when any check fails.

set -u

TARGET="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -d "$TARGET" ] || { echo "Target directory does not exist: $TARGET" >&2; exit 66; }
TARGET=$(cd "$TARGET" && pwd)

FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); printf 'ok   %s\n' "$1"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf 'FAIL %s\n' "$1"; [ $# -lt 2 ] || printf '     %s\n' "$2"; }
note() { printf '     %s\n' "$1"; }

echo "session-journal doctor — $TARGET"
echo

# --- Where are the journals? ------------------------------------------------

SETTINGS="$TARGET/.claude/settings.json"
CODEX_SETTINGS="$TARGET/.codex/hooks.json"
SESSIONS_REL="sessions"
STOP_COMMAND=""
START_COMMAND=""

read_command() {
  local file=$1 hook=$2
  [ -e "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --arg hook "$hook" '
    [.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // ""]
    | map(select(contains($hook))) | first // ""
  ' "$file" 2>/dev/null || printf ''
}

for candidate_settings in "$SETTINGS" "$CODEX_SETTINGS"; do
  [ -n "$START_COMMAND" ] || START_COMMAND=$(read_command "$candidate_settings" session-journal-pointer.sh)
  [ -n "$STOP_COMMAND" ] || STOP_COMMAND=$(read_command "$candidate_settings" session-journal-nudge.sh)
done

case "$STOP_COMMAND$START_COMMAND" in
  *SESSION_JOURNAL_DIR=*)
    SESSIONS_REL=$(printf '%s' "$STOP_COMMAND$START_COMMAND" \
      | sed -n 's|.*SESSION_JOURNAL_DIR="[^"]*/\([^"]*\)".*|\1|p' | head -n 1)
    [ -n "$SESSIONS_REL" ] || SESSIONS_REL="sessions"
    ;;
esac
SESSIONS_DIR="$TARGET/$SESSIONS_REL"

# --- Installation ------------------------------------------------------------

if command -v jq >/dev/null 2>&1; then
  pass "jq is available"
else
  fail "jq is available" "settings cannot be inspected or merged without it"
fi

if [ -e "$SETTINGS" ] || [ -e "$CODEX_SETTINGS" ]; then
  for candidate_settings in "$SETTINGS" "$CODEX_SETTINGS"; do
    [ -e "$candidate_settings" ] || continue
    if ! command -v jq >/dev/null 2>&1; then continue; fi
    if jq -e . "$candidate_settings" >/dev/null 2>&1; then
      pass "${candidate_settings#"$TARGET"/} is valid JSON"
    else
      fail "${candidate_settings#"$TARGET"/} is valid JSON"
    fi
  done
else
  fail "a settings file exists" "no .claude/settings.json and no .codex/hooks.json"
fi

if [ -n "$START_COMMAND" ]; then
  pass "a SessionStart hook is registered"
else
  fail "a SessionStart hook is registered" "no command referencing session-journal-pointer.sh"
fi
if [ -n "$STOP_COMMAND" ]; then
  pass "a Stop hook is registered"
else
  fail "a Stop hook is registered" "no command referencing session-journal-nudge.sh"
fi

POINTER="$TARGET/.claude/hooks/session-journal-pointer.sh"
NUDGE="$TARGET/.claude/hooks/session-journal-nudge.sh"
for script in "$POINTER" "$NUDGE"; do
  label="${script#"$TARGET"/}"
  if [ ! -e "$script" ]; then
    fail "$label exists"
  elif [ ! -x "$script" ]; then
    fail "$label is executable" "chmod +x $script"
  elif ! bash -n "$script" 2>/dev/null; then
    fail "$label parses"
  else
    pass "$label is present, executable, and parses"
    stamped=$(sed -n 's|.*session-journal \([0-9][0-9.]*\).*|\1|p' "$script" | head -n 1)
    [ -z "$stamped" ] || note "version $stamped"
  fi
done

# The registered command must actually resolve. A hook installed into a
# subdirectory of a git repository writes a runtime-relative path that points
# somewhere that does not exist, and then fails silently forever.
if [ -n "$STOP_COMMAND" ]; then
  # Resolve the command's path the way the runtime would, without eval: the
  # generated command is "$(git rev-parse --show-toplevel ... || pwd)/<tail>",
  # so recompute that root here and rejoin it with the literal tail.
  RUNTIME_ROOT=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$TARGET")
  resolved=$(printf '%s' "$STOP_COMMAND" | sed -n 's|.*)\(/[^"]*session-journal-nudge\.sh\)".*|\1|p' | head -n 1)
  if [ -n "$resolved" ]; then
    resolved="$RUNTIME_ROOT$resolved"
  else
    resolved=$(printf '%s' "$STOP_COMMAND" | sed -n 's|.*"\(/[^"]*session-journal-nudge\.sh\)".*|\1|p' | head -n 1)
  fi
  if [ -z "$resolved" ]; then
    note "could not parse the Stop command path; skipping resolution check"
  elif [ -x "$resolved" ]; then
    pass "the registered Stop command resolves to an executable script"
  else
    fail "the registered Stop command resolves" "$resolved is missing or not executable"
  fi
fi

# --- Journal directory -------------------------------------------------------

if [ -d "$SESSIONS_DIR" ]; then
  pass "journal directory exists ($SESSIONS_REL/)"
else
  fail "journal directory exists" "$SESSIONS_DIR is missing"
fi
if [ -e "$SESSIONS_DIR/README.md" ]; then
  pass "$SESSIONS_REL/README.md exists"
else
  fail "$SESSIONS_REL/README.md exists" "agents have no local contract to follow"
fi
if [ -e "$SESSIONS_DIR/TEMPLATE.md" ]; then
  pass "$SESSIONS_REL/TEMPLATE.md exists"
else
  fail "$SESSIONS_REL/TEMPLATE.md exists" "the hooks tell agents to start from a template that is not installed"
fi

if command -v git >/dev/null 2>&1 && git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$TARGET" check-ignore -q "$SESSIONS_DIR" 2>/dev/null; then
    note "journals are gitignored: continuity is local-only and teammates will not receive it"
  else
    pass "journals are tracked by git and will reach teammates"
  fi
  if [ -e "$SETTINGS" ] && git -C "$TARGET" check-ignore -q "$SETTINGS" 2>/dev/null; then
    fail "the hook settings are committed" ".claude/settings.json is gitignored, so only this machine runs the hooks"
  elif [ -e "$SETTINGS" ]; then
    if [ -n "$(git -C "$TARGET" status --porcelain -- "$SETTINGS" "$POINTER" "$NUDGE" 2>/dev/null)" ]; then
      fail "the installation is committed" "commit .claude/ so teammates get the same hooks"
    else
      pass "the installation is committed"
    fi
  fi
fi

# --- Behaviour ---------------------------------------------------------------

if [ -x "$POINTER" ]; then
  if OUTPUT=$(CLAUDE_PROJECT_DIR="$TARGET" SESSION_JOURNAL_DIR="$SESSIONS_DIR" "$POINTER" 2>/dev/null); then
    if command -v jq >/dev/null 2>&1 && ! printf '%s' "$OUTPUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null 2>&1; then
      fail "the pointer emits valid SessionStart JSON"
    else
      pass "the pointer emits valid SessionStart JSON"
      case "$OUTPUT" in
        *"No session journal exists"*) note "no journal yet: the next substantive session should create one" ;;
        *"finished session"*) note "every journal is DONE: the next session starts fresh" ;;
        *) note "$(printf '%s' "$OUTPUT" | sed -n 's|.*journal: \([^ .]*\.md\).*|pointing at \1|p' | head -n 1)" ;;
      esac
    fi
  else
    fail "the pointer runs cleanly"
  fi
fi

if [ -x "$NUDGE" ]; then
  STATUS=0
  printf '%s' '{"stop_hook_active":true}' \
    | CLAUDE_PROJECT_DIR="$TARGET" SESSION_JOURNAL_DIR="$SESSIONS_DIR" "$NUDGE" >/dev/null 2>&1 || STATUS=$?
  if [ "$STATUS" -eq 0 ]; then
    pass "stop_hook_active suppresses the freshness nudge (no infinite loop)"
  elif [ "$STATUS" -eq 2 ]; then
    fail "stop_hook_active suppresses the freshness nudge" "the newest journal has secret-looking content; run the Stop hook directly to see the line numbers"
  else
    fail "the nudge runs cleanly" "exit status $STATUS"
  fi

  # Only meaningful once a journal exists: with an empty directory the nudge
  # exits 2 for the missing journal, which is not a secrets finding.
  JOURNAL_COUNT=0
  for candidate in "$SESSIONS_DIR"/*.md; do
    [ -e "$candidate" ] || continue
    case "$(basename "$candidate")" in README.md|TEMPLATE.md) continue ;; esac
    JOURNAL_COUNT=$((JOURNAL_COUNT + 1))
  done
  if [ "$JOURNAL_COUNT" -eq 0 ]; then
    note "no journal to scan for secrets yet"
  else
    STATUS=0
    printf '%s' '{"stop_hook_active":false}' \
      | CLAUDE_PROJECT_DIR="$TARGET" SESSION_JOURNAL_DIR="$SESSIONS_DIR" JOURNAL_FRESH_SECS=999999999 SESSION_JOURNAL_SKIP=1 "$NUDGE" >/dev/null 2>&1 || STATUS=$?
    if [ "$STATUS" -eq 0 ]; then
      pass "the newest journal is free of secret-looking content"
    elif [ "$STATUS" -eq 2 ]; then
      fail "the newest journal is free of secret-looking content" "run the Stop hook directly for the line numbers"
    else
      fail "the secrets guard runs cleanly" "exit status $STATUS"
    fi
  fi
fi

# --- Instruction blocks ------------------------------------------------------

for instructions in "$TARGET/CLAUDE.md" "$TARGET/AGENTS.md"; do
  [ -e "$instructions" ] || continue
  label="${instructions#"$TARGET"/}"
  begins=$(grep -c '<!-- session-journal:begin -->' "$instructions" 2>/dev/null || true)
  ends=$(grep -c '<!-- session-journal:end -->' "$instructions" 2>/dev/null || true)
  if [ "$begins" -eq 0 ] && [ "$ends" -eq 0 ]; then
    note "$label has no session-journal block"
  elif [ "$begins" -eq "$ends" ]; then
    pass "$label carries a balanced session-journal block"
  else
    fail "$label carries a balanced session-journal block" "$begins begin marker(s), $ends end marker(s)"
  fi
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "$CHECKS checks passed."
  exit 0
fi
echo "$FAILURES of $CHECKS checks failed."
exit 1
