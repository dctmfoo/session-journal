#!/bin/bash
# Deterministic installer for a cloned session-journal repository.

set -e

usage() {
  echo "Usage: ./install.sh /path/to/target-repo [--sessions-dir path] [--codex] [--no-claude] [--uninstall]" >&2
  exit 64
}

[ "$#" -ge 1 ] || usage
TARGET=$1
shift
SESSIONS_REL="sessions"
INSTALL_CODEX=false
INSTALL_CLAUDE=true
UNINSTALL=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sessions-dir)
      [ "$#" -ge 2 ] || usage
      SESSIONS_REL=$2
      shift 2
      ;;
    --codex) INSTALL_CODEX=true; shift ;;
    --no-claude) INSTALL_CLAUDE=false; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$SESSIONS_REL" in
  /*|../*|*/../*|*'/..')
    echo "--sessions-dir must be a path inside the target repository" >&2
    exit 64
    ;;
esac

[ -d "$TARGET" ] || { echo "Target directory does not exist: $TARGET" >&2; exit 66; }
TARGET=$(cd "$TARGET" && pwd)
SOURCE=$(cd "$(dirname "$0")" && pwd)

command -v jq >/dev/null 2>&1 || { echo "jq is required to merge hook settings safely." >&2; exit 69; }

validate_json_file() {
  local file=$1
  [ ! -e "$file" ] || jq -e . "$file" >/dev/null 2>&1 || {
    echo "$file is not valid JSON (comments/JSON5 are not modified). Merge hooks manually from hooks/*.snippet.json." >&2
    exit 65
  }
}

merge_hooks() {
  local file=$1
  local runtime=$2
  local pointer_command=$3
  local nudge_command=$4
  local start_matcher="*"
  [ "$runtime" = "codex" ] && start_matcher="startup|resume|clear|compact"
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || printf '%s\n' '{}' > "$file"
  local tmp="$file.session-journal.tmp"
  jq --arg pointer "$pointer_command" --arg nudge "$nudge_command" --arg matcher "$start_matcher" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = ([.hooks.SessionStart[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-pointer.sh")) | not)] + [{matcher:$matcher,hooks:[{type:"command",command:$pointer}]}])
    | .hooks.Stop = ([.hooks.Stop[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-nudge.sh")) | not)] + [{hooks:[{type:"command",command:$nudge}]}])
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

remove_hooks() {
  local file=$1
  [ -e "$file" ] || return 0
  validate_json_file "$file"
  local tmp="$file.session-journal.tmp"
  jq '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = [.hooks.SessionStart[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-pointer.sh")) | not)]
    | .hooks.Stop = [.hooks.Stop[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-nudge.sh")) | not)]
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

strip_owned_block() {
  local destination=$1
  awk '
    /<!-- session-journal:begin -->/ { skipping=1; next }
    /<!-- session-journal:end -->/ { skipping=0; next }
    !skipping { print }
  ' "$destination"
}

replace_owned_block() {
  local destination=$1
  local template=$2
  local tmp="$destination.session-journal.tmp"
  [ -e "$destination" ] || : > "$destination"
  strip_owned_block "$destination" > "$tmp"
  while [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; do printf '\n' >> "$tmp"; break; done
  {
    printf '%s\n' '<!-- session-journal:begin -->'
    sed "s|{{SESSIONS_DIR}}|$SESSIONS_REL|g" "$template"
    printf '%s\n' '<!-- session-journal:end -->'
  } >> "$tmp"
  mv "$tmp" "$destination"
}

remove_owned_block() {
  local destination=$1
  [ -e "$destination" ] || return 0
  local tmp="$destination.session-journal.tmp"
  strip_owned_block "$destination" > "$tmp"
  mv "$tmp" "$destination"
}

CLAUDE_SETTINGS="$TARGET/.claude/settings.json"
CODEX_SETTINGS="$TARGET/.codex/hooks.json"

if [ "$UNINSTALL" = true ]; then
  remove_hooks "$CLAUDE_SETTINGS"
  remove_hooks "$CODEX_SETTINGS"
  rm -f "$TARGET/.claude/hooks/session-journal-pointer.sh" "$TARGET/.claude/hooks/session-journal-nudge.sh"
  remove_owned_block "$TARGET/CLAUDE.md"
  remove_owned_block "$TARGET/AGENTS.md"
  echo "Session-journal hooks and instruction blocks removed. Journals and their README were kept as project history."
  exit 0
fi

[ "$INSTALL_CLAUDE" = false ] || validate_json_file "$CLAUDE_SETTINGS"
[ "$INSTALL_CODEX" = false ] || validate_json_file "$CODEX_SETTINGS"

mkdir -p "$TARGET/.claude/hooks" "$TARGET/$SESSIONS_REL"
cp "$SOURCE/hooks/session-journal-pointer.sh" "$TARGET/.claude/hooks/session-journal-pointer.sh"
cp "$SOURCE/hooks/session-journal-nudge.sh" "$TARGET/.claude/hooks/session-journal-nudge.sh"
chmod +x "$TARGET/.claude/hooks/session-journal-pointer.sh" "$TARGET/.claude/hooks/session-journal-nudge.sh"
TIMEZONE=$(date +%Z 2>/dev/null || printf '%s' local)
sed "s|{{SESSIONS_DIR}}|$SESSIONS_REL|g; s|{{DEFAULT_PLAN_POINTER}}|none|g; s|{{TIMEZONE}}|$TIMEZONE|g; s|{{EVIDENCE_VOCABULARY}}|commit hashes, test names, issue IDs, and document section references|g" \
  "$SOURCE/templates/sessions-README.md" > "$TARGET/$SESSIONS_REL/README.md"

ENV_PREFIX=""
[ "$SESSIONS_REL" = "sessions" ] || ENV_PREFIX="SESSION_JOURNAL_DIR=\"$TARGET/$SESSIONS_REL\" "
POINTER_COMMAND="${ENV_PREFIX}\"\$(git rev-parse --show-toplevel)/.claude/hooks/session-journal-pointer.sh\""
NUDGE_COMMAND="${ENV_PREFIX}\"\$(git rev-parse --show-toplevel)/.claude/hooks/session-journal-nudge.sh\""

if [ "$INSTALL_CLAUDE" = true ]; then
  merge_hooks "$CLAUDE_SETTINGS" claude "$POINTER_COMMAND" "$NUDGE_COMMAND"
  replace_owned_block "$TARGET/CLAUDE.md" "$SOURCE/templates/CLAUDE.md-section.md"
fi
if [ "$INSTALL_CODEX" = true ]; then
  merge_hooks "$CODEX_SETTINGS" codex "$POINTER_COMMAND" "$NUDGE_COMMAND"
  replace_owned_block "$TARGET/AGENTS.md" "$SOURCE/templates/AGENTS.md-section.md"
fi

echo "Session journal installed at $SESSIONS_REL/. Run the verification steps in ADOPT.md Phase C before relying on it."
if [ "$INSTALL_CODEX" = true ]; then
  echo "Codex: trust this project and review the new hook definitions with /hooks before expecting them to run."
fi
