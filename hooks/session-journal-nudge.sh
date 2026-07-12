#!/bin/bash
# Stop hook: enforce a fresh session journal and reject secret-looking content.
#
# Claude Code and Codex pass JSON on stdin. stop_hook_active prevents a second
# freshness block, while the secrets guard always runs. Some runners provide no
# stdin; for those only, a short-lived marker supplies one-shot loop protection.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in
  /*) ;;
  *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;;
esac
FRESH_SECS="${JOURNAL_FRESH_SECS:-300}"

INPUT=""
IFS= read -r -t 2 INPUT 2>/dev/null || true
STOP_ACTIVE=false
if [ -n "$INPUT" ]; then
  if command -v python3 >/dev/null 2>&1; then
    STOP_ACTIVE=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print("true" if json.load(sys.stdin).get("stop_hook_active") is True else "false")
except Exception: print("false")' 2>/dev/null || printf false)
  elif command -v jq >/dev/null 2>&1; then
    STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == true then "true" else "false" end' 2>/dev/null || printf false)
  elif printf '%s' "$INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    STOP_ACTIVE=true
  fi
fi

MARKER=""
if [ -z "$INPUT" ]; then
  PROJECT_KEY=$(printf '%s' "$PROJECT_DIR" | cksum | awk '{print $1}')
  MARKER="${TMPDIR:-/tmp}/session-journal-nudge-$PROJECT_KEY.d"
  if [ -d "$MARKER" ]; then
    rmdir "$MARKER" 2>/dev/null || true
    STOP_ACTIVE=true
  fi
fi

mkdir -p "$SESSIONS_DIR"
LATEST=""
for candidate in "$SESSIONS_DIR"/*.md; do
  [ -e "$candidate" ] || continue
  [ "$(basename "$candidate")" = "README.md" ] && continue
  if [ -z "$LATEST" ] || [ "$candidate" -nt "$LATEST" ]; then
    LATEST="$candidate"
  fi
done

# The allowlist applies only to the line carrying the marker. Values are never
# echoed back: diagnostics identify line numbers so a hook cannot leak a secret.
if [ -n "$LATEST" ]; then
  LEAK_LINES=$(grep -nEv '<!-- journal-secrets-ok -->' "$LATEST" 2>/dev/null \
    | grep -Ei 'e[y]J[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{16,}|(client[_-]?secret|api[_-]?key|password|passphrase|token)[[:space:]]*[:=][[:space:]]*[^[:space:]]{6,}|[0-9a-f]{40,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' \
    | cut -d: -f1 | head -n 3 | paste -sd, - || true)
  if [ -n "$LEAK_LINES" ]; then
    echo "SESSION-JOURNAL-SECRETS-GUARD: secret-looking content found in $LATEST at line(s) $LEAK_LINES. Redact values to key names or safe length-only descriptions before finishing." >&2
    exit 2
  fi
fi

if [ "$STOP_ACTIVE" = "true" ]; then
  printf '{}\n'
  exit 0
fi

block_once() {
  [ -z "$MARKER" ] || mkdir "$MARKER" 2>/dev/null || true
  echo "$1" >&2
  exit 2
}

if [ -z "$LATEST" ]; then
  block_once "SESSION-JOURNAL-REMINDER: No session journal exists. Create YYYY-MM-DD-HHMM-<slug>.md from the local template before finishing resumable work."
fi

if ! MTIME=$(stat -f %m "$LATEST" 2>/dev/null); then
  MTIME=$(stat -c %Y "$LATEST")
fi
NOW=$(date +%s)
AGE=$((NOW - MTIME))
if [ "$AGE" -lt "$FRESH_SECS" ]; then
  printf '{}\n'
  exit 0
fi

PLAN_LINE=$(awk '
  /^## Live plan pointer[[:space:]]*$/ { inside=1; next }
  inside && /^## / { exit }
  inside && NF { print; exit }
' "$LATEST" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
PLAN_LOWER=$(printf '%s' "$PLAN_LINE" | tr '[:upper:]' '[:lower:]')

case "$PLAN_LOWER" in
  ""|none|\<none\>*)
    block_once "SESSION-JOURNAL-REMINDER (DETAILED mode): the newest journal is ${AGE}s old. Update milestones, files, current state, next step, and Last updated; promote recurring work into a durable plan and switch to THIN."
    ;;
  *)
    block_once "SESSION-JOURNAL-REMINDER (THIN mode — pointer: $PLAN_LINE): the newest journal is ${AGE}s old. Add one-line evidence and refresh current state, next step, and Last updated without duplicating the governing document."
    ;;
esac
