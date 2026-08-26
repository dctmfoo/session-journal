#!/bin/bash
# Stop hook: enforce a fresh session journal and reject secret-looking content.
#
# Claude Code and Codex pass JSON on stdin. stop_hook_active prevents a second
# freshness block, while the secrets guard always runs. Some runners provide no
# stdin; for those only, a short-lived marker supplies one-shot loop protection.
#
# session-journal 1.1.0 — https://github.com/dctmfoo/session-journal (MIT)

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
SESSIONS_DIR="${SESSION_JOURNAL_DIR:-$PROJECT_DIR/sessions}"
case "$SESSIONS_DIR" in
  /*) ;;
  *) SESSIONS_DIR="$PROJECT_DIR/$SESSIONS_DIR" ;;
esac

FRESH_SECS="${JOURNAL_FRESH_SECS:-300}"
case "$FRESH_SECS" in
  ''|*[!0-9]*)
    echo "SESSION-JOURNAL: JOURNAL_FRESH_SECS='$FRESH_SECS' is not a whole number of seconds; using 300." >&2
    FRESH_SECS=300
    ;;
esac

# One-shot markers exist to break a stop cascade within a single session. Without
# a TTL the marker outlives the session that armed it and silently swallows the
# next session's first nudge, so anything older than this is treated as stale.
MARKER_TTL="${JOURNAL_STOP_MARKER_TTL_SECS:-60}"
case "$MARKER_TTL" in
  ''|*[!0-9]*) MARKER_TTL=60 ;;
esac

# Read the WHOLE stdin payload, not just its first line. A single `read` stops
# at the first newline, so a runner that pretty-prints its hook JSON would hand
# us "{", which defeats the stop_hook_active check AND suppresses the marker
# fallback below (because the payload is non-empty), leaving no loop protection
# at all. The per-read timeout is kept: some runners attach a stdin they never
# close, and a plain `cat` would hang the Stop hook forever.
INPUT=""
STDIN_LINE=""
while IFS= read -r -t 2 STDIN_LINE; do
  INPUT="$INPUT$STDIN_LINE
"
  STDIN_LINE=""
done
[ -z "$STDIN_LINE" ] || INPUT="$INPUT$STDIN_LINE"

STOP_ACTIVE=false
if [ -n "$INPUT" ]; then
  if command -v python3 >/dev/null 2>&1; then
    STOP_ACTIVE=$(printf '%s' "$INPUT" | python3 -c 'import json,sys
try: print("true" if json.load(sys.stdin).get("stop_hook_active") is True else "false")
except Exception: print("false")' 2>/dev/null || printf false)
  elif command -v jq >/dev/null 2>&1; then
    STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r 'if .stop_hook_active == true then "true" else "false" end' 2>/dev/null || printf false)
  elif printf '%s' "$INPUT" | tr '\n' ' ' | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    STOP_ACTIVE=true
  fi
fi

MARKER=""
if [ -z "$INPUT" ]; then
  PROJECT_KEY=$(printf '%s' "$PROJECT_DIR" | cksum | awk '{print $1}')
  MARKER="${TMPDIR:-/tmp}/session-journal-nudge-$PROJECT_KEY.d"
  if [ -d "$MARKER" ]; then
    MARKER_MTIME=""
    MARKER_MTIME=$(stat -f %m "$MARKER" 2>/dev/null || stat -c %Y "$MARKER" 2>/dev/null || printf '')
    rmdir "$MARKER" 2>/dev/null || true
    if [ -n "$MARKER_MTIME" ] && [ "$(( $(date +%s) - MARKER_MTIME ))" -le "$MARKER_TTL" ]; then
      STOP_ACTIVE=true
    fi
  fi
fi

# A Stop hook is not an installer: it must not create the sessions directory as
# a side effect. The glob below handles a nonexistent directory correctly.

# Newest journal: mtime leads, filename settles ties. mtime alone is wrong
# whenever several journals share a timestamp -- a fresh `git clone`, a branch
# checkout, an unpacked archive -- because bash 3.2 compares `-nt` at
# whole-second resolution and the tie keeps the alphabetically OLDEST file.
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

# The allowlist applies only to the line carrying the marker. Values are never
# echoed back: diagnostics identify line numbers so a hook cannot leak a secret.
if [ -n "$LATEST" ]; then
  CANDIDATES=$(grep -nEv '<!-- journal-secrets-ok -->' "$LATEST" 2>/dev/null || true)

  # Credential shapes that carry their own prefix are unambiguous: a JWT, a
  # bearer value, an AWS key id, a GitHub or Slack token, a private-key header.
  NAMED=$(printf '%s\n' "$CANDIDATES" \
    | grep -Ei 'e[y]J[A-Za-z0-9_-]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{16,}|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{16,}|-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----' || true)

  # `key: value` assignments need the VALUE inspected, not just the key name.
  # The old pattern flagged any 6+ non-space token after a credential key, which
  # blocked `password: <redacted>` and `token: stored-in-ci-secrets` -- the exact
  # remediations this hook's own error message prescribes, producing a block ->
  # redact -> block loop the runtime cannot break. A value is now reported only
  # when it is long enough to be a credential, drawn from a credential alphabet,
  # and not a placeholder -- either a leading symbol (<redacted>, $ENV_VAR) or a
  # leading word that describes where the secret lives (stored-in-ci-secrets).
  ASSIGNED=$(awk '
    function is_placeholder(v,   head) {
      if (v ~ /^[<${*("'"'"'\[]/) return 1
      head = v
      sub(/[-_.:].*$/, "", head)
      return (head ~ /^(redacted|redact|redacts|placeholder|example|sample|dummy|fake|test|none|null|nil|unset|empty|blank|omitted|elided|scrubbed|masked|hidden|removed|rotated|expired|revoked|sanitized|sanitised|todo|tbd|changeme|see|stored|store|kept|held|managed|provided|supplied|injected|configured|set|use|using|from|in|via|your|my|the|not|no|never|only|env|vault|keychain|n)$/)
    }
    {
      if ($0 ~ /<!-- journal-secrets-ok -->/) next
      line = $0
      if (match(tolower(line), /(client[_-]?secret|api[_-]?key|secret[_-]?key|access[_-]?key|password|passphrase|token)[[:space:]]*[:=][[:space:]]*/) == 0) next
      value = substr(line, RSTART + RLENGTH)
      sub(/[[:space:]].*$/, "", value)
      sub(/[",;.)]+$/, "", value)
      if (length(value) < 12) next
      if (value !~ /^[A-Za-z0-9._~+\/=-]+$/) next
      if (is_placeholder(tolower(value))) next
      print NR ":" line
    }
  ' "$LATEST" 2>/dev/null || true)

  # A bare long hex string is only suspicious away from digest context. SHA-256
  # artifact receipts, git revisions, and fingerprints are this program's
  # evidence, not secrets, and must survive verbatim to stay verifiable.
  #
  # Context is read over a three-line window, NOT the hash's own line. Prose
  # wraps, and a 64-character digest routinely lands on a line of its own with
  # "hashes to" or "SHA-256" ending the line above; a single-line check sees a
  # bare hex string and cries wolf.
  #
  # Every non-alphanumeric run collapses to a single space before matching, so
  # the keywords compare as whole words. Substring matching let "Avoid",
  # "Android" and "paranoid" satisfy `oid`, and "committed" satisfy `commit`,
  # silently disabling hex detection for their neighbouring lines.
  BARE_HEX=$(awk '
    { lines[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) {
        if (lines[i] ~ /<!-- journal-secrets-ok -->/) continue
        ctx = " " tolower((i > 1 ? lines[i-1] : "") " " lines[i] " " (i < NR ? lines[i+1] : "")) " "
        gsub(/[^a-z0-9]+/, " ", ctx)
        if (ctx ~ / (sha|sha1|sha256|sha384|sha512|hash|hashes|hashed|digest|digests|checksum|checksums|fingerprint|fingerprints|commit|commits|revision|revisions|blob|blobs|oid|oids|etag|etags) /) continue
        print i ":" lines[i]
      }
    }' "$LATEST" 2>/dev/null | grep -Ei '[0-9a-f]{40,}' || true)

  LEAK_LINES=$(printf '%s\n%s\n%s\n' "$NAMED" "$ASSIGNED" "$BARE_HEX" \
    | grep -E '^[0-9]+:' | cut -d: -f1 | sort -n -u | head -n 3 | paste -sd, - || true)
  if [ -n "$LEAK_LINES" ]; then
    echo "SESSION-JOURNAL-SECRETS-GUARD: secret-looking content found in $LATEST at line(s) $LEAK_LINES (first three shown). Replace the value with a key name, an env-var reference, or a placeholder such as <redacted>. If a human has confirmed the line carries no credential value, append <!-- journal-secrets-ok --> to that line to exempt it." >&2
    exit 2
  fi
fi

if [ "$STOP_ACTIVE" = "true" ]; then
  printf '{}\n'
  exit 0
fi

# A trivial session -- a typo fix, a dependency bump -- does not need a journal.
# Without a documented escape the only ways out are to burn stop_hook_active or
# to write a journal about nothing, and both teach the agent to route around the
# discipline. The secrets guard above deliberately still runs.
case "${SESSION_JOURNAL_SKIP:-}" in
  ''|0|false|no) ;;
  *) printf '{}\n'; exit 0 ;;
esac

block_once() {
  [ -z "$MARKER" ] || mkdir "$MARKER" 2>/dev/null || true
  echo "$1" >&2
  exit 2
}

if [ -z "$LATEST" ]; then
  block_once "SESSION-JOURNAL-REMINDER: No session journal exists. Create YYYY-MM-DD-HHMM-<slug>.md from the local template before finishing resumable work. If this session needs no journal, set SESSION_JOURNAL_SKIP=1."
fi

if ! MTIME=$(stat -f %m "$LATEST" 2>/dev/null); then
  MTIME=$(stat -c %Y "$LATEST" 2>/dev/null || printf '0')
fi
NOW=$(date +%s)
AGE=$((NOW - MTIME))

PLAN_LINE=$(awk '
  tolower($0) ~ /^##[[:space:]]+live plan pointer[[:space:]]*$/ { inside=1; next }
  inside && /^## / { exit }
  inside && NF { print; exit }
' "$LATEST" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)
PLAN_LOWER=$(printf '%s' "$PLAN_LINE" | tr '[:upper:]' '[:lower:]')

mode_reminder() {
  case "$PLAN_LOWER" in
    ""|none|\<none\>*)
      block_once "SESSION-JOURNAL-REMINDER (DETAILED mode): $1 Update milestones, files, current state, next step, and Last updated; promote recurring work into a durable plan and switch to THIN."
      ;;
    *)
      block_once "SESSION-JOURNAL-REMINDER (THIN mode — pointer: $PLAN_LINE): $1 Add one-line evidence and refresh current state, next step, and Last updated without duplicating the governing document."
      ;;
  esac
}

# Freshness by mtime alone measures a property the agent can set directly: a
# bare `touch` satisfies the gate with zero characters changed. When git can
# tell us whether the journal actually moved, require content, not a timestamp.
journal_records_work() {
  local journal=$1 dirty journal_dirty
  case "${JOURNAL_REQUIRE_CONTENT_CHANGE:-1}" in
    0|false|no) return 0 ;;
  esac
  command -v git >/dev/null 2>&1 || return 0
  git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # Local-only journals are invisible to `git status`; fall back to mtime.
  if git -C "$PROJECT_DIR" check-ignore -q "$journal" 2>/dev/null; then return 0; fi
  dirty=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -n 200 || true)
  # Nothing changed anywhere: there is no work for the journal to record.
  [ -n "$dirty" ] || return 0
  journal_dirty=$(git -C "$PROJECT_DIR" status --porcelain -- "$journal" 2>/dev/null || true)
  [ -z "$journal_dirty" ] || return 0
  return 1
}

if [ "$AGE" -lt "$FRESH_SECS" ]; then
  if journal_records_work "$LATEST"; then
    printf '{}\n'
    exit 0
  fi
  mode_reminder "the newest journal's timestamp moved but its content did not, while other files in this repository did change."
fi

mode_reminder "the newest journal is ${AGE}s old."
