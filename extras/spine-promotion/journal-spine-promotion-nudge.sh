#!/bin/bash
# Optional Stop hook for recurring DETAILED journals.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in /*) ;; *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;; esac
THRESHOLD="${SPINE_PROMOTION_THRESHOLD:-6}"
TARGET_HINT="${SPINE_PROMOTION_TARGET_HINT:-docs/plans/}"

LATEST=""
for candidate in "$SESSIONS_DIR"/*.md; do
  [ -e "$candidate" ] || continue
  [ "$(basename "$candidate")" = "README.md" ] && continue
  if [ -z "$LATEST" ] || [ "$candidate" -nt "$LATEST" ]; then LATEST="$candidate"; fi
done
[ -n "$LATEST" ] || { printf '{}\n'; exit 0; }

PLAN=$(awk '/^## Live plan pointer[[:space:]]*$/{inside=1;next} inside&&/^## /{exit} inside&&NF{print;exit}' "$LATEST" 2>/dev/null || true)
[ -z "$PLAN" ] || [ "$(printf '%s' "$PLAN" | tr '[:upper:]' '[:lower:]')" = "none" ] || { printf '{}\n'; exit 0; }

COUNT=$(awk '/^## Milestones[[:space:]]*$/{inside=1;next} inside&&/^## /{exit} inside&&/^[[:space:]]*[-*] /{count++} END{print count+0}' "$LATEST")
if [ "$COUNT" -ge "$THRESHOLD" ]; then
  echo "SESSION-JOURNAL-SPINE-PROMOTION: this DETAILED journal has $COUNT milestones. Promote recurring work into a durable plan or specification under $TARGET_HINT, point the journal to it, and continue in THIN mode." >&2
  exit 2
fi
printf '{}\n'
