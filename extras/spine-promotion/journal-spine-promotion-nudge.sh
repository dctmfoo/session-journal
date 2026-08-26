#!/bin/bash
# Optional Stop hook for recurring DETAILED journals.
#
# session-journal <VERSION> — https://github.com/dctmfoo/session-journal (MIT)

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in /*) ;; *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;; esac
THRESHOLD="${SPINE_PROMOTION_THRESHOLD:-6}"
TARGET_HINT="${SPINE_PROMOTION_TARGET_HINT:-docs/plans/}"

# Newest journal: mtime leads, filename settles ties. See the long note in
# session-journal-pointer.sh for why mtime alone picks the oldest after a clone.
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
[ -n "$LATEST" ] || { printf '{}\n'; exit 0; }

# Headings match case-insensitively, as the specification requires and as both
# core hooks do. Left exact, this hook read a title-cased THIN journal as
# DETAILED and blocked Stop with a message that was simply untrue.
PLAN=$(awk 'tolower($0) ~ /^##[[:space:]]+live plan pointer[[:space:]]*$/{inside=1;next} inside&&/^## /{exit} inside&&NF{print;exit}' "$LATEST" 2>/dev/null || true)
[ -z "$PLAN" ] || [ "$(printf '%s' "$PLAN" | tr '[:upper:]' '[:lower:]')" = "none" ] || { printf '{}\n'; exit 0; }

# An unreadable journal must not hand raw awk diagnostics to the agent as a Stop
# block. Failing open here is correct: this is an optional advisory nudge, and
# the core freshness and secrets hooks own the enforcement path.
COUNT=$(awk 'tolower($0) ~ /^##[[:space:]]+milestones[[:space:]]*$/{inside=1;next} inside&&/^## /{exit} inside&&/^[[:space:]]*[-*] /{count++} END{print count+0}' "$LATEST" 2>/dev/null || printf '0')
case "$COUNT" in
  ''|*[!0-9]*) COUNT=0 ;;
esac
if [ "$COUNT" -ge "$THRESHOLD" ]; then
  echo "SESSION-JOURNAL-SPINE-PROMOTION: this DETAILED journal has $COUNT milestones. Promote recurring work into a durable plan or specification under $TARGET_HINT, point the journal to it, and continue in THIN mode." >&2
  exit 2
fi
printf '{}\n'
