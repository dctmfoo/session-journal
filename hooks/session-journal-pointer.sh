#!/bin/bash
# SessionStart hook: inject a compact pointer to the live session journal.
# Compatible with bash 3.2 and with Claude Code and Codex command hooks.
#
# session-journal <VERSION> — https://github.com/dctmfoo/session-journal (MIT)

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in
  /*) ;;
  *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;;
esac

# A SessionStart hook is a read path. It must not create directories: a
# read-only checkout or a mistargeted PROJECT_DIR would turn a missing-context
# event into a nonzero exit and lose the injection entirely. The glob below
# handles a nonexistent directory correctly on its own.

journal_status() {
  # First word of the mandatory status line, upper-cased. Empty when absent.
  sed -n 's/^[[:space:]]*\*\*Status:\*\*[[:space:]]*//p' "$1" 2>/dev/null \
    | head -n 1 \
    | awk '{print toupper($1)}' \
    | tr -cd '[:upper:]'
}

# "Newest" is decided by modification time, with the filename as the tie-break.
# mtime alone is wrong whenever a filesystem hands several journals the same
# timestamp -- a fresh `git clone`, a branch checkout, an unpacked archive, a
# restored backup -- because bash 3.2 compares `-nt` at whole-second resolution
# and the tie silently keeps whichever name the glob yielded first, i.e. the
# OLDEST journal. The filename is the session-start time by specification and
# sorts lexicographically, so it settles ties correctly. mtime still leads, so a
# journal appended to across days stays live even though its name is older.
LATEST=""
LATEST_BASE=""
for candidate in "$SESSIONS_DIR"/*.md; do
  [ -e "$candidate" ] || continue
  base=$(basename "$candidate")
  case "$base" in README.md|TEMPLATE.md) continue ;; esac
  if [ -z "$LATEST" ]; then
    LATEST=$candidate
    LATEST_BASE=$base
  elif [ "$candidate" -nt "$LATEST" ]; then
    LATEST=$candidate
    LATEST_BASE=$base
  elif [ ! "$LATEST" -nt "$candidate" ] && [ "$base" \> "$LATEST_BASE" ]; then
    LATEST=$candidate
    LATEST_BASE=$base
  fi
done

# A DONE journal is a finished session, not the live frontier. Prefer the newest
# journal still open for work; fall back to reporting the closed one honestly
# rather than replaying its "no work remains" next step to a fresh agent.
LIVE=""
LIVE_BASE=""
if [ -n "$LATEST" ] && [ "$(journal_status "$LATEST")" = "DONE" ]; then
  for candidate in "$SESSIONS_DIR"/*.md; do
    [ -e "$candidate" ] || continue
    base=$(basename "$candidate")
    case "$base" in README.md|TEMPLATE.md) continue ;; esac
    case "$(journal_status "$candidate")" in
      ACTIVE|BLOCKED) ;;
      *) continue ;;
    esac
    if [ -z "$LIVE" ]; then
      LIVE=$candidate
      LIVE_BASE=$base
    elif [ "$candidate" -nt "$LIVE" ]; then
      LIVE=$candidate
      LIVE_BASE=$base
    elif [ ! "$LIVE" -nt "$candidate" ] && [ "$base" \> "$LIVE_BASE" ]; then
      LIVE=$candidate
      LIVE_BASE=$base
    fi
  done
fi

relative_path() {
  local resolved="${1#"$PROJECT_DIR"/}"
  [ "$resolved" = "$1" ] && resolved="$1"
  printf '%s' "$resolved"
}

if [ -z "$LATEST" ]; then
  REL_SESSIONS=$(relative_path "$SESSIONS_DIR")
  MESSAGE="No session journal exists in $REL_SESSIONS/. Once this session's intent is clear, create YYYY-MM-DD-HHMM-<slug>.md from $REL_SESSIONS/TEMPLATE.md and follow $REL_SESSIONS/README.md."
else
  CLOSED=""
  if [ "$(journal_status "$LATEST")" = "DONE" ]; then
    if [ -n "$LIVE" ]; then
      CLOSED=$(relative_path "$LATEST")
      LATEST=$LIVE
    else
      CLOSED="only"
    fi
  fi

  RELATIVE=$(relative_path "$LATEST")
  STATUS_LINE=$(grep -m 1 '^[[:space:]]*\*\*Status:\*\*' "$LATEST" 2>/dev/null || true)
  [ -n "$STATUS_LINE" ] || STATUS_LINE="**Status:** Status not recorded"

  # Heading matching is case-insensitive: a journal written from memory rather
  # than from the template routinely title-cases the heading, and an exact match
  # silently drops the one section this hook exists to deliver.
  NEXT_STEP=$(awk '
    tolower($0) ~ /^##[[:space:]]+next step for a fresh agent[[:space:]]*$/ { inside=1; next }
    inside && /^## / { exit }
    inside { print }
  ' "$LATEST" 2>/dev/null | sed '/^[[:space:]]*$/d' || true)
  if [ -z "$NEXT_STEP" ]; then
    NEXT_STEP="Next step not recorded. This journal has no \"## Next step for a fresh agent\" section; read it in full, then add that section before ending the turn."
  fi

  if [ "$CLOSED" = "only" ]; then
    MESSAGE="Most recent session journal: $RELATIVE — its status is DONE, so it is a finished session and not the live frontier. Read it for background, treat this session as new work, and create a new journal once the intent is clear.
$STATUS_LINE
Last recorded next step (from the closed journal):
$NEXT_STEP"
  elif [ -n "$CLOSED" ]; then
    MESSAGE="Live session journal: $RELATIVE. Read it before acting. Continue the same work by appending to it; start unrelated work in a new journal. A more recent journal ($CLOSED) is already DONE and is background only.
$STATUS_LINE
Next step for a fresh agent:
$NEXT_STEP"
  else
    MESSAGE="Most recent session journal: $RELATIVE. Read it before acting. Continue the same work by appending to it; start unrelated work in a new journal.
$STATUS_LINE
Next step for a fresh agent:
$NEXT_STEP"
  fi
fi

json_string() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  elif command -v python >/dev/null 2>&1; then
    python -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
  else
    # Minimal documented fallback: preserve valid JSON by escaping the control
    # characters a journal can realistically contain, then flattening newlines.
    sed 's/\\/\\\\/g; s/"/\\"/g' \
      | tr '\t' ' ' \
      | tr -d '\r' \
      | tr '\n' ' ' \
      | sed 's/^/"/; s/$/"/'
  fi
}

ESCAPED=$(printf '%s' "$MESSAGE" | json_string)
printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$ESCAPED"
exit 0
