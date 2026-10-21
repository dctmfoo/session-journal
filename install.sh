#!/bin/bash
# Deterministic installer for a cloned session-journal repository.

set -e

usage() {
  cat >&2 <<'USAGE'
Usage: ./install.sh /path/to/target-repo [options]

  --sessions-dir <path>   Journal directory, relative to the target repo (default: sessions)
  --plan-pointer <value>  Default "Live plan pointer" for the generated README (default: none)
  --codex                 Also install Codex hooks, the Codex skill, and the AGENTS.md block
  --no-claude             Skip Claude Code hooks, the Claude skill, and the CLAUDE.md block
  --no-skill              Do not install the session-journal agent skill
  --refresh-docs          Regenerate the sessions README, TEMPLATE.md, and the
                          instruction blocks, discarding local adaptations
  --uninstall             Remove the owned hooks, script, skills, and instruction blocks
USAGE
  exit 64
}

[ "$#" -ge 1 ] || usage
case "$1" in -h|--help) usage ;; esac
TARGET=$1
shift
SESSIONS_REL="sessions"
SESSIONS_REL_EXPLICIT=false
PLAN_POINTER="none"
INSTALL_CODEX=false
INSTALL_CLAUDE=true
INSTALL_SKILL=true
REFRESH_DOCS=false
UNINSTALL=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sessions-dir)
      [ "$#" -ge 2 ] || usage
      SESSIONS_REL=$2
      SESSIONS_REL_EXPLICIT=true
      shift 2
      ;;
    --plan-pointer)
      [ "$#" -ge 2 ] || usage
      PLAN_POINTER=$2
      shift 2
      ;;
    --codex) INSTALL_CODEX=true; shift ;;
    --no-claude) INSTALL_CLAUDE=false; shift ;;
    --no-skill) INSTALL_SKILL=false; shift ;;
    --refresh-docs) REFRESH_DOCS=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$SESSIONS_REL" in
  ""|.|..|/*|./*|../*|*/./*|*/../*|*/.|*/..|*[!A-Za-z0-9._/-]*)
    echo "--sessions-dir must be a path inside the target repository" >&2
    exit 64
    ;;
esac
SESSIONS_REL=${SESSIONS_REL%/}

case "$PLAN_POINTER" in
  *[\"\\]*|*"|"*|*"
"*)
    echo "--plan-pointer must not contain quotes, backslashes, pipes, or newlines" >&2
    exit 64
    ;;
esac

[ -d "$TARGET" ] || { echo "Target directory does not exist: $TARGET" >&2; exit 66; }
TARGET=$(cd "$TARGET" && pwd)
TARGET_REAL=$(cd "$TARGET" && pwd -P)
SOURCE=$(cd "$(dirname "$0")" && pwd)
VERSION=$(cat "$SOURCE/VERSION" 2>/dev/null || printf 'unknown')

command -v jq >/dev/null 2>&1 || { echo "jq is required to merge hook settings safely." >&2; exit 69; }

CLAUDE_SETTINGS="$TARGET/.claude/settings.json"
CODEX_SETTINGS="$TARGET/.codex/hooks.json"
SCRIPT_NAME="session-journal.py"
SCRIPT="$TARGET/.claude/hooks/$SCRIPT_NAME"
CLAUDE_SKILL="$TARGET/.claude/skills/session-journal"
CODEX_SKILL="$TARGET/.agents/skills/session-journal"
STATE_DIR="$TARGET/.claude/state/session-journal"
# Every hook group a release of this project has owned. v1 shipped two shell
# scripts; 2.0 replaces both with one Python program. Matching all three names
# is what lets an install double as the v1 -> v2 migration.
OWNED_PATTERN="session-journal\\.py|session-journal-pointer\\.sh|session-journal-nudge\\.sh"
# The optional 1.x spine-promotion Stop hook is now built into session-journal.py
# (SPINE_PROMOTION_THRESHOLD). Its groups are removed with ours, and its
# settings are carried onto the generated Stop command.
SPINE_PATTERN="journal-spine-promotion-nudge\\.sh"
REMOVE_PATTERN="$OWNED_PATTERN|$SPINE_PATTERN"
LEGACY_SCRIPTS="session-journal-pointer.sh session-journal-nudge.sh journal-spine-promotion-nudge.sh"

validate_json_file() {
  local file=$1
  [ ! -e "$file" ] || jq -e . "$file" >/dev/null 2>&1 || {
    echo "$file is not valid JSON (comments/JSON5 are not modified). Merge hooks manually from hooks/*.snippet.json." >&2
    exit 65
  }
}

sentinels_balanced() {
  local destination=$1 begins ends
  [ -e "$destination" ] || return 0
  begins=$(grep -c '<!-- session-journal:begin -->' "$destination" 2>/dev/null || true)
  ends=$(grep -c '<!-- session-journal:end -->' "$destination" 2>/dev/null || true)
  [ "$begins" -eq "$ends" ] || {
    echo "$destination has an unmatched session-journal sentinel; refusing to modify it." >&2
    return 65
  }
}

strip_owned_block() {
  awk '
    /<!-- session-journal:begin -->/ { skipping=1; next }
    /<!-- session-journal:end -->/ { skipping=0; next }
    !skipping { print }
  ' "$1"
}

has_owned_block() {
  [ -e "$1" ] && grep -q '<!-- session-journal:begin -->' "$1" 2>/dev/null
}

# `&` in a sed replacement expands to the whole match, so an unescaped value
# containing one silently rewrites itself into the placeholder it was replacing:
# --plan-pointer 'docs/a&b.md' produced 'docs/a{{DEFAULT_PLAN_POINTER}}b.md'.
sed_replacement() {
  printf '%s' "$1" | sed 's/[&\\|]/\\&/g'
}

render_template() {
  sed "s|{{SESSIONS_DIR}}|$(sed_replacement "$SESSIONS_REL")|g; s|{{DEFAULT_PLAN_POINTER}}|$(sed_replacement "$PLAN_POINTER")|g; s|{{TIMEZONE}}|$(sed_replacement "$TIMEZONE")|g; s|{{EVIDENCE_VOCABULARY}}|$(sed_replacement "$EVIDENCE_VOCABULARY")|g" "$1"
}

replace_owned_block() {
  local destination=$1 template=$2 label=$3
  if has_owned_block "$destination" && [ "$REFRESH_DOCS" = false ]; then
    echo "Kept the existing session-journal block in $label (re-run with --refresh-docs to regenerate it)."
    return 0
  fi
  local tmp="$destination.session-journal.tmp"
  [ -e "$destination" ] || : > "$destination"
  strip_owned_block "$destination" > "$tmp"
  if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; then printf '\n' >> "$tmp"; fi
  {
    printf '%s\n' '<!-- session-journal:begin -->'
    render_template "$template"
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
  # replace_owned_block creates the instruction file when a repository has none.
  # Leaving a zero-byte CLAUDE.md or AGENTS.md behind is not the reverse of an
  # install: tools that look for one would find an empty contract.
  [ -s "$destination" ] || rm -f "$destination"
}

# Remove every hook group that runs an owned script, under every event. Groups
# that mix an owned command with a foreign one keep the foreign command.
remove_hooks() {
  local file=$1
  [ -e "$file" ] || return 0
  validate_json_file "$file"
  local tmp="$file.session-journal.tmp"
  jq --arg owned "$REMOVE_PATTERN" '
    if (.hooks | type) == "object" then
      .hooks |= with_entries(.value |= (
        [ .[]? | .hooks = [ (.hooks // [])[] | select((.command // "") | test($owned) | not) ]
               | select((.hooks | length) > 0) ]))
    else . end
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# The command currently registered for an event, if it runs an owned script.
existing_command() {
  local file=$1 event=$2
  [ -e "$file" ] || return 0
  jq -r --arg event "$event" --arg owned "$OWNED_PATTERN" '
    [(.hooks // {})[$event][]? | .hooks[]? | .command // ""]
    | map(select(test($owned))) | first // ""
  ' "$file" 2>/dev/null || printf ''
}

# The 1.x spine-promotion command registered under Stop, if any.
spine_command() {
  [ -e "$1" ] || return 0
  jq -r --arg spine "$SPINE_PATTERN" '
    [(.hooks // {}).Stop[]? | .hooks[]? | .command // ""] | map(select(test($spine))) | first // ""
  ' "$1" 2>/dev/null || printf ''
}

# Leading NAME=value assignments of a command -- the one place a shell env
# prefix can legally live. Quoted values are parsed rather than stripped.
# `keep` is "all", or "foreign" to drop SESSION_JOURNAL_DIR, which the
# installer owns. v1-only knobs that 2.0 no longer reads are dropped too.
parse_env_prefix() {
  local rest=$1 keep=$2 name value out=""
  while :; do
    case "$rest" in
      [A-Za-z_]*=*) ;;
      *) break ;;
    esac
    name=${rest%%=*}
    case "$name" in *[!A-Za-z0-9_]*) break ;; esac
    rest=${rest#*=}
    if [ "${rest#\"}" != "$rest" ]; then
      rest=${rest#\"}
      value="\"${rest%%\"*}\""
      rest=${rest#*\"}
    else
      value=${rest%% *}
      rest=${rest#"$value"}
    fi
    case "$keep:$name" in
      all:*) out="$out$name=$value " ;;
      foreign:SESSION_JOURNAL_DIR|foreign:JOURNAL_FRESH_SECS|foreign:JOURNAL_REQUIRE_CONTENT_CHANGE|foreign:JOURNAL_STOP_MARKER_TTL_SECS) ;;
      *) out="$out$name=$value " ;;
    esac
    rest=${rest# }
  done
  printf '%s' "$out"
}

# The journal directory a previous install wired into this settings file, as a
# path relative to the repository root, or empty when the default is in use.
# v1 wrote SESSION_JOURNAL_DIR="$(git rev-parse ...)/<dir>"; 2.0 writes the
# relative path, which the script resolves against the main checkout.
configured_sessions_dir() {
  local file=$1 event existing value
  for event in Stop SessionStart; do
    existing=$(existing_command "$file" "$event")
    [ -n "$existing" ] || continue
    value=$(parse_env_prefix "$existing" all | sed -nE 's/^(.* )?SESSION_JOURNAL_DIR=("[^"]*"|[^ "]+).*/\2/p' | head -n 1)
    [ -n "$value" ] || continue
    value=${value#\"}
    value=${value%\"}
    case "$value" in *")/"*) value=${value##*)/} ;; esac
    printf '%s' "$value"
    return 0
  done
}

if [ "$UNINSTALL" = true ]; then
  # Refuse before touching anything, so a refusal never leaves a half state.
  # Both files are checked regardless of the runtime flags, because
  # remove_owned_block below strips both regardless of the runtime flags.
  sentinels_balanced "$TARGET/CLAUDE.md" || exit 65
  sentinels_balanced "$TARGET/AGENTS.md" || exit 65
  validate_json_file "$CLAUDE_SETTINGS"
  validate_json_file "$CODEX_SETTINGS"
  remove_hooks "$CLAUDE_SETTINGS"
  remove_hooks "$CODEX_SETTINGS"
  rm -f "$SCRIPT"
  for legacy in $LEGACY_SCRIPTS; do rm -f "$TARGET/.claude/hooks/$legacy"; done
  rm -rf "${CLAUDE_SKILL:?}" "${CODEX_SKILL:?}" "${STATE_DIR:?}"
  remove_owned_block "$TARGET/CLAUDE.md"
  remove_owned_block "$TARGET/AGENTS.md"
  # Directories the install created and that are now empty; anything else stays.
  for dir in .claude/hooks .claude/skills .claude/state .agents/skills .agents; do
    rmdir "$TARGET/$dir" 2>/dev/null || true
  done
  echo "Session-journal hooks, script, skills, local state, and instruction blocks removed. Journals, their README, and TEMPLATE.md were kept as project history."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight. Every refusal happens here, before the first byte is written.
# ---------------------------------------------------------------------------

[ "$INSTALL_CLAUDE" = false ] || validate_json_file "$CLAUDE_SETTINGS"
[ "$INSTALL_CODEX" = false ] || validate_json_file "$CODEX_SETTINGS"
[ "$INSTALL_CLAUDE" = false ] || sentinels_balanced "$TARGET/CLAUDE.md" || exit 65
[ "$INSTALL_CODEX" = false ] || sentinels_balanced "$TARGET/AGENTS.md" || exit 65

if ! command -v python3 >/dev/null 2>&1; then
  echo "Note: python3 is not on PATH here. The hooks need Python 3.8+ wherever the agent runs; without it they do nothing (each command ends in '|| true' so a missing interpreter never blocks the agent)." >&2
fi

# The installed hook commands resolve their root at runtime. Installing into a
# subdirectory of a git repository writes a command that points at a path
# which does not exist, and the hooks fail silently forever. Catch it here.
if GIT_TOPLEVEL=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null); then
  GIT_TOPLEVEL=$(cd "$GIT_TOPLEVEL" && pwd -P)
  if [ "$GIT_TOPLEVEL" != "$TARGET_REAL" ]; then
    echo "$TARGET is inside a git repository but is not its root ($GIT_TOPLEVEL)." >&2
    echo "The installed hooks resolve their root with 'git rev-parse --show-toplevel' at runtime, so they would look for themselves in the wrong place. Install into the repository root instead." >&2
    exit 65
  fi
  # A linked worktree shares its journals with the main checkout; installing
  # here would commit hooks on a branch while the journals live elsewhere.
  GIT_COMMON=$(git -C "$TARGET" rev-parse --git-common-dir 2>/dev/null || printf '')
  case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$TARGET/$GIT_COMMON" ;; esac
  if [ "$(basename "$GIT_COMMON")" = ".git" ] && [ "$(cd "$(dirname "$GIT_COMMON")" && pwd -P)" != "$TARGET_REAL" ]; then
    echo "Note: $TARGET is a linked worktree. The hooks keep journals in the main checkout ($(dirname "$GIT_COMMON")); commit this install on the branch the main checkout uses." >&2
  fi
else
  echo "Note: $TARGET is not a git repository. The hook commands fall back to the agent's working directory at runtime; start the agent from the repository root." >&2
fi

# A rerun without --sessions-dir must not silently relocate the journal
# directory: rebuilding the command from the default orphaned every existing
# journal while reporting success.
if [ "$SESSIONS_REL_EXPLICIT" = false ]; then
  for candidate_settings in "$CLAUDE_SETTINGS" "$CODEX_SETTINGS"; do
    [ -e "$candidate_settings" ] || continue
    existing_dir=$(configured_sessions_dir "$candidate_settings")
    if [ -n "$existing_dir" ] && [ "$existing_dir" != "$SESSIONS_REL" ]; then
      SESSIONS_REL=$existing_dir
      echo "Reusing the journal directory already configured here: $SESSIONS_REL/ (pass --sessions-dir to move it)."
      break
    fi
  done
fi

# A symlinked journal directory that escapes the repository silently makes
# journals unreviewable: they stop being part of the project's git history.
SESSIONS_ABS="$TARGET/$SESSIONS_REL"
if [ -e "$SESSIONS_ABS" ]; then
  SESSIONS_REAL=$(cd "$SESSIONS_ABS" 2>/dev/null && pwd -P || printf '')
  case "$SESSIONS_REAL" in
    "$TARGET_REAL"|"$TARGET_REAL"/*) ;;
    *)
      echo "$SESSIONS_ABS resolves to $SESSIONS_REAL, outside $TARGET_REAL; refusing to install journals outside the repository." >&2
      exit 65
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Writes start here.
# ---------------------------------------------------------------------------

TIMEZONE=$(date +%Z 2>/dev/null || printf '%s' local)
EVIDENCE_VOCABULARY="commit hashes, test names, issue IDs, and document section references"

mkdir -p "$TARGET/.claude/hooks" "$SESSIONS_ABS"

cp "$SOURCE/hooks/$SCRIPT_NAME" "$SCRIPT"
chmod +x "$SCRIPT"
for legacy in $LEGACY_SCRIPTS; do
  if [ -e "$TARGET/.claude/hooks/$legacy" ]; then
    rm -f "$TARGET/.claude/hooks/$legacy"
    echo "Removed the 1.x hook script .claude/hooks/$legacy (replaced by $SCRIPT_NAME)."
  fi
done

# The sessions README is the adopting agent's artifact: a rerun must not revert
# the adaptation work ADOPT.md asks for.
if [ -e "$SESSIONS_ABS/README.md" ] && [ "$REFRESH_DOCS" = false ]; then
  echo "Kept the existing $SESSIONS_REL/README.md (re-run with --refresh-docs to regenerate it)."
else
  render_template "$SOURCE/templates/sessions-README.md" > "$SESSIONS_ABS/README.md"
fi
if [ -e "$SESSIONS_ABS/TEMPLATE.md" ] && [ "$REFRESH_DOCS" = false ]; then
  echo "Kept the existing $SESSIONS_REL/TEMPLATE.md (re-run with --refresh-docs to regenerate it)."
else
  render_template "$SOURCE/templates/session-journal.md" > "$SESSIONS_ABS/TEMPLATE.md"
fi

install_skill() {
  local source=$1 destination=$2
  [ "$INSTALL_SKILL" = true ] || return 0
  rm -rf "${destination:?}"
  mkdir -p "$(dirname "$destination")"
  cp -R "$source" "$destination"
}

# Claude Code exports CLAUDE_PROJECT_DIR; Codex does not, and runs hooks in the
# session's working directory, where git finds the root.
RUNTIME_ROOT="\${CLAUDE_PROJECT_DIR:-\$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
GENERATED_PREFIX=""
[ "$SESSIONS_REL" = "sessions" ] || GENERATED_PREFIX="SESSION_JOURNAL_DIR=$SESSIONS_REL "

merge_hooks() {
  local file=$1 runtime=$2 groups="[]" event matcher timeout env command
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || printf '%s\n' '{}' > "$file"

  for event in SessionStart UserPromptSubmit PreToolUse PostToolUse Stop SessionEnd; do
    matcher=""
    timeout=10
    case "$runtime:$event" in
      claude:SessionStart) matcher="*"; timeout=15 ;;
      codex:SessionStart) matcher="startup|resume|clear|compact"; timeout=15 ;;
      claude:PreToolUse|claude:PostToolUse) matcher="Edit|Write|MultiEdit|NotebookEdit|Bash" ;;
      codex:PreToolUse|codex:PostToolUse) matcher="Bash|apply_patch" ;;
      *:Stop) timeout=30 ;;
      claude:SessionEnd) timeout=5 ;;
      codex:SessionEnd) timeout=3 ;;
    esac
    env=$(parse_env_prefix "$(existing_command "$file" "$event")" foreign)
    if [ "$event" = Stop ]; then
      spine=$(spine_command "$file")
      if [ -n "$spine" ]; then
        spine_env=$(parse_env_prefix "$spine" all | tr ' ' '\n' | grep '^SPINE_PROMOTION_' | tr '\n' ' ')
        case "$env$spine_env" in *SPINE_PROMOTION_THRESHOLD=*) ;; *) spine_env="${spine_env}SPINE_PROMOTION_THRESHOLD=6 " ;; esac
        case "$env" in *SPINE_PROMOTION_*) spine_env="" ;; esac
        env="$env$spine_env"
        echo "Migrated the spine-promotion Stop hook into $SCRIPT_NAME (${spine_env:-settings already present})."
      fi
    fi
    [ -z "$env" ] || echo "Preserved environment overrides on the $event command: $env"
    # `|| true`: a missing interpreter or script exits 127 or 2, and exit 2
    # from a hook blocks the tool call or the turn. A journal hook must never.
    command="${env}${GENERATED_PREFIX}python3 \"$RUNTIME_ROOT/.claude/hooks/$SCRIPT_NAME\" hook $event || true"
    groups=$(jq -c --arg event "$event" --arg matcher "$matcher" --arg command "$command" --argjson timeout "$timeout" '
      . + [{event: $event, group: ((if $matcher == "" then {} else {matcher: $matcher} end)
                                   + {hooks: [{type: "command", command: $command, timeout: $timeout}]})}]
    ' <<< "$groups")
  done

  remove_hooks "$file"
  local tmp="$file.session-journal.tmp"
  jq --argjson groups "$groups" '
    .hooks = ((.hooks // {}) | if type == "object" then . else {} end)
    | reduce $groups[] as $g (.; .hooks[$g.event] = ((.hooks[$g.event] // []) + [$g.group]))
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ "$INSTALL_CLAUDE" = true ]; then
  merge_hooks "$CLAUDE_SETTINGS" claude
  replace_owned_block "$TARGET/CLAUDE.md" "$SOURCE/templates/CLAUDE.md-section.md" CLAUDE.md
  install_skill "$SOURCE/skills/session-journal" "$CLAUDE_SKILL"
fi
if [ "$INSTALL_CODEX" = true ]; then
  merge_hooks "$CODEX_SETTINGS" codex
  replace_owned_block "$TARGET/AGENTS.md" "$SOURCE/templates/AGENTS.md-section.md" AGENTS.md
  install_skill "$SOURCE/codex/skills/session-journal" "$CODEX_SKILL"
fi

echo "Session journal $VERSION installed at $SESSIONS_REL/. Run ./doctor.sh $TARGET before relying on it, then commit .claude/$( [ "$INSTALL_CODEX" = true ] && printf ', .codex/, .agents/'), the instruction blocks, and $SESSIONS_REL/."
if [ "$INSTALL_CODEX" = true ]; then
  echo "Codex: trust this project and review the new hook definitions with /hooks before expecting them to run."
fi
