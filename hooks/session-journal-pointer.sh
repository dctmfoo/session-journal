#!/bin/bash
# SessionStart hook: inject a compact pointer to the newest session journal.
# Compatible with bash 3.2 and with Claude Code and Codex command hooks.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in
  /*) ;;
  *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;;
esac

mkdir -p "$SESSIONS_DIR"

LATEST=""
for candidate in "$SESSIONS_DIR"/*.md; do
  [ -e "$candidate" ] || continue
  [ "$(basename "$candidate")" = "README.md" ] && continue
  if [ -z "$LATEST" ] || [ "$candidate" -nt "$LATEST" ]; then
    LATEST="$candidate"
  fi
done

if [ -z "$LATEST" ]; then
  REL_SESSIONS="${SESSIONS_DIR#"$PROJECT_DIR"/}"
  [ "$REL_SESSIONS" = "$SESSIONS_DIR" ] && REL_SESSIONS="$SESSIONS_DIR"
  MESSAGE="No session journal exists in $REL_SESSIONS/. Once this session's intent is clear, create YYYY-MM-DD-HHMM-<slug>.md using the local sessions README and template."
else
  RELATIVE="${LATEST#"$PROJECT_DIR"/}"
  [ "$RELATIVE" = "$LATEST" ] && RELATIVE="$LATEST"
  STATUS_LINE=$(grep -m 1 '^\*\*Status:\*\*' "$LATEST" 2>/dev/null || true)
  [ -n "$STATUS_LINE" ] || STATUS_LINE="**Status:** Status not recorded"
  NEXT_STEP=$(awk '
    /^## Next step for a fresh agent[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$LATEST" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
  [ -n "$NEXT_STEP" ] || NEXT_STEP="Next step not recorded"
  MESSAGE="Most recent session journal: $RELATIVE. Read it before acting. Continue the same work by appending to it; start unrelated work in a new journal.
$STATUS_LINE
Next step for a fresh agent:
$NEXT_STEP"
fi

json_string() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  elif command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    # Minimal documented fallback: preserve valid JSON by flattening newlines.
    sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/^/"/; s/$/"/'
  fi
}

ESCAPED=$(printf '%s' "$MESSAGE" | json_string)
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
exit 0
