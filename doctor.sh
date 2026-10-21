#!/bin/bash
# Re-runnable self-check for an adopted session-journal installation.
#
# Hooks that stop firing are silent by construction: a SessionStart hook that
# never runs looks exactly like a session with no journal, and a Stop hook that
# never runs looks exactly like a journal that is always up to date. This
# script lets a teammate, a CI job, or a suspicious agent check at any time.
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

SETTINGS="$TARGET/.claude/settings.json"
CODEX_SETTINGS="$TARGET/.codex/hooks.json"
SCRIPT="$TARGET/.claude/hooks/session-journal.py"
EVENTS="SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SessionEnd"
HAVE_JQ=false
command -v jq >/dev/null 2>&1 && HAVE_JQ=true

# The command registered for an event in a settings file, if it runs the script.
# The event matters, not just the presence of the string: a command registered
# under some other event must not be reported as a working hook.
read_command() {
  local file=$1 event=$2
  [ -e "$file" ] && [ "$HAVE_JQ" = true ] || return 0
  jq -r --arg event "$event" '
    [(.hooks // {})[$event][]? | .hooks[]? | .command // ""]
    | map(select(contains("session-journal.py"))) | first // ""
  ' "$file" 2>/dev/null || printf ''
}

# --- Tools -------------------------------------------------------------------

if [ "$HAVE_JQ" = true ]; then pass "jq is available"; else fail "jq is available" "settings cannot be inspected or merged without it"; fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null; then
  pass "python3 3.8+ is available ($(python3 -c 'import platform; print(platform.python_version())'))"
else
  fail "python3 3.8+ is available" "every hook command ends in '|| true', so without Python the hooks silently do nothing"
fi

# --- Wiring ------------------------------------------------------------------

SESSIONS_REL=""
RUNTIMES=0
for candidate_settings in "$SETTINGS" "$CODEX_SETTINGS"; do
  [ -e "$candidate_settings" ] || continue
  label="${candidate_settings#"$TARGET"/}"
  if [ "$HAVE_JQ" = true ] && ! jq -e . "$candidate_settings" >/dev/null 2>&1; then
    fail "$label is valid JSON"
    continue
  fi
  wired=""
  missing=""
  for event in $EVENTS; do
    command=$(read_command "$candidate_settings" "$event")
    if [ -n "$command" ]; then
      wired="$wired $event"
      case "$command" in *"|| true"*) ;; *) fail "$label $event command ends in '|| true'" "exit 2 from a missing interpreter would block the agent" ;; esac
      if [ -z "$SESSIONS_REL" ]; then
        SESSIONS_REL=$(printf '%s' "$command" | sed -nE 's/^(.* )?SESSION_JOURNAL_DIR=("[^"]*"|[^ "]+).*/\2/p' | head -n 1 | tr -d '"')
      fi
    else
      missing="$missing $event"
    fi
  done
  [ -n "$wired" ] || continue
  RUNTIMES=$((RUNTIMES + 1))
  if [ -z "$missing" ]; then
    pass "$label wires all six journal hooks"
  else
    fail "$label wires all six journal hooks" "missing:$missing (re-run ./install.sh)"
  fi
  if [ "$HAVE_JQ" = true ] && jq -e '[.hooks // {} | .[]?[]? | .hooks[]? | .command // "" | select(test("session-journal-(pointer|nudge)\\.sh"))] | length > 0' "$candidate_settings" >/dev/null 2>&1; then
    fail "$label carries no v1 hooks" "v1 pointer/nudge hooks still registered; re-run ./install.sh to migrate"
  fi
done
[ "$RUNTIMES" -gt 0 ] || fail "a runtime is wired" "no session-journal.py hooks in .claude/settings.json or .codex/hooks.json"
case "$SESSIONS_REL" in *")/"*) SESSIONS_REL=${SESSIONS_REL##*)/} ;; esac
[ -n "$SESSIONS_REL" ] || SESSIONS_REL="sessions"
SESSIONS_DIR="$TARGET/$SESSIONS_REL"

if [ ! -e "$SCRIPT" ]; then
  fail ".claude/hooks/session-journal.py exists"
elif ! VERSION_OUT=$(python3 "$SCRIPT" version 2>/dev/null); then
  fail ".claude/hooks/session-journal.py runs" "python3 $SCRIPT version failed"
else
  pass ".claude/hooks/session-journal.py runs (version $VERSION_OUT)"
fi
for legacy in session-journal-pointer.sh session-journal-nudge.sh; do
  [ ! -e "$TARGET/.claude/hooks/$legacy" ] || note "v1 script .claude/hooks/$legacy is still on disk; ./install.sh removes it"
done

# --- Journal directory -------------------------------------------------------

if [ -d "$SESSIONS_DIR" ]; then
  pass "journal directory exists ($SESSIONS_REL/)"
else
  fail "journal directory exists" "$SESSIONS_DIR is missing; the hooks stay inactive without it"
fi
for doc in README.md TEMPLATE.md; do
  if [ -e "$SESSIONS_DIR/$doc" ]; then pass "$SESSIONS_REL/$doc exists"; else fail "$SESSIONS_REL/$doc exists" "re-run ./install.sh"; fi
done

if command -v git >/dev/null 2>&1 && git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$TARGET" check-ignore -q "$SESSIONS_DIR" 2>/dev/null; then
    note "journals are gitignored: continuity is local-only and teammates will not receive it"
  else
    pass "journals are tracked by git and will reach teammates"
  fi
  if [ -e "$SETTINGS" ] && git -C "$TARGET" check-ignore -q "$SETTINGS" 2>/dev/null; then
    fail "the hook settings are committed" ".claude/settings.json is gitignored, so only this machine runs the hooks"
  else
    paths=""
    for p in "$SETTINGS" "$CODEX_SETTINGS" "$SCRIPT"; do [ -e "$p" ] && paths="$paths $p"; done
    # shellcheck disable=SC2086
    if [ -n "$paths" ] && [ -n "$(git -C "$TARGET" status --porcelain -- $paths 2>/dev/null)" ]; then
      fail "the installation is committed" "commit .claude/ (and .codex/) so teammates get the same hooks"
    elif [ -n "$paths" ]; then
      pass "the installation is committed"
    fi
  fi
  if [ -d "$TARGET/.claude/state/session-journal" ] && \
     [ -n "$(git -C "$TARGET" status --porcelain --untracked-files=all -- .claude/state/session-journal 2>/dev/null)" ]; then
    fail "local hook state stays out of git" ".claude/state/session-journal/ shows in git status; restore its .gitignore ('*')"
  fi
fi

# --- Behaviour ---------------------------------------------------------------
# Run the real hooks against a scratch state directory, so the check neither
# reads nor disturbs the leases of sessions that are running right now.

if [ -e "$SCRIPT" ] && [ -d "$SESSIONS_DIR" ] && command -v python3 >/dev/null 2>&1; then
  SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/session-journal-doctor.XXXXXX")
  run_hook() {
    printf '%s' "$2" | (cd "$TARGET" && env -u CLAUDE_PROJECT_DIR -u JOURNAL_ROLE -u SESSION_JOURNAL_DISABLE \
      SESSION_JOURNAL_STATE_DIR="$SCRATCH" SESSION_JOURNAL_DIR="$SESSIONS_REL" \
      python3 "$SCRIPT" hook "$1" 2>"$SCRATCH/stderr")
  }
  OUTPUT=$(run_hook SessionStart "{\"session_id\":\"doctor-check\",\"source\":\"startup\",\"cwd\":\"$TARGET\"}")
  if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["hookEventName"]=="SessionStart"' 2>/dev/null; then
    pass "SessionStart returns journal context"
    printf '%s' "$OUTPUT" | python3 -c '
import json, sys
ctx = json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]
rows = [l.strip() for l in ctx.splitlines() if l.strip().startswith("- ")]
print("     %d open candidate journal(s)%s" % (len(rows), (": first " + rows[0][2:].split(" [")[0]) if rows else ""))'
  else
    fail "SessionStart returns journal context" "$(head -c 200 "$SCRATCH/stderr")"
  fi
  OUTPUT=$(run_hook Stop "{\"session_id\":\"doctor-check\",\"stop_hook_active\":false,\"cwd\":\"$TARGET\"}")
  if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    pass "Stop returns JSON and does not nudge a turn that landed nothing"
    case "$OUTPUT" in *'"block"'*) fail "a read-only turn is not nudged" "$OUTPUT" ;; esac
  else
    fail "Stop returns JSON" "got: $(printf '%s' "$OUTPUT" | head -c 200)"
  fi
  if SCAN=$(cd "$TARGET" && env -u CLAUDE_PROJECT_DIR SESSION_JOURNAL_STATE_DIR="$SCRATCH" SESSION_JOURNAL_DIR="$SESSIONS_REL" python3 "$SCRIPT" scan 2>&1); then
    pass "no journal carries credential-shaped content"
  else
    fail "no journal carries credential-shaped content" "$(printf '%s' "$SCAN" | head -n 5 | tr '\n' ' ')"
  fi
  rm -rf "${SCRATCH:?}"
fi

if [ -d "$TARGET/.claude/state/session-journal" ] && command -v python3 >/dev/null 2>&1 && [ -e "$SCRIPT" ]; then
  errors=$(cd "$TARGET" && env -u CLAUDE_PROJECT_DIR SESSION_JOURNAL_DIR="$SESSIONS_REL" python3 "$SCRIPT" health 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("hook_errors", 0))' 2>/dev/null || printf '?')
  if [ "$errors" = "0" ]; then
    pass "the hooks have logged no errors on this machine"
  else
    fail "the hooks have logged no errors on this machine" "$errors error(s); see .claude/state/session-journal/events.jsonl"
  fi
fi

# --- Instruction blocks and skills -------------------------------------------

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
for skill in .claude/skills/session-journal .agents/skills/session-journal; do
  [ -e "$TARGET/$skill/SKILL.md" ] && note "skill installed: $skill"
done

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "$CHECKS checks passed."
  exit 0
fi
echo "$FAILURES of $CHECKS checks failed."
exit 1
