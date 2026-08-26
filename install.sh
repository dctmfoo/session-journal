#!/bin/bash
# Deterministic installer for a cloned session-journal repository.

set -e

usage() {
  cat >&2 <<'USAGE'
Usage: ./install.sh /path/to/target-repo [options]

  --sessions-dir <path>   Journal directory, relative to the target repo (default: sessions)
  --plan-pointer <value>  Default "Live plan pointer" for the generated README (default: none)
  --codex                 Also install Codex hooks and the AGENTS.md block
  --no-claude             Skip Claude Code hooks and the CLAUDE.md block
  --refresh-docs          Regenerate the sessions README, TEMPLATE.md, and the
                          instruction blocks, discarding local adaptations
  --uninstall             Remove the owned hooks, scripts, and instruction blocks
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
  while [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | wc -l | tr -d ' ')" -eq 0 ]; do printf '\n' >> "$tmp"; break; done
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

# ADOPT.md Phase B tells the adopting agent to add environment overrides such as
# JOURNAL_FRESH_SECS to the generated command. Rebuilding the command from
# scratch deleted them on every re-run, so carry any foreign assignments across.
# ADOPT.md Phase B tells the adopting agent to add environment overrides such as
# JOURNAL_FRESH_SECS to the generated command. Rebuilding the command from
# scratch deleted them on every re-run, so carry any foreign assignments across.
#
# Only the leading assignments of the matching command are read -- that is the
# one place a shell env prefix can legally live -- and quoted values are parsed
# rather than stripped. Stripping quotes first turned NAME="value" into NAME=,
# silently dropping exactly the override this exists to preserve, and reading
# the whole command string would let an unrelated hook that merely mentions the
# script name contribute text to a freshly generated command.
existing_command() {
  local file=$1 event=$2 hook=$3
  [ -e "$file" ] || return 0
  jq -r --arg event "$event" --arg hook "$hook" '
    [(.hooks // {})[$event][]? | .hooks[]? | .command // ""]
    | map(select(contains($hook))) | first // ""
  ' "$file" 2>/dev/null || printf ''
}

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
    if [ "$keep" = "all" ] || [ "$name" != "SESSION_JOURNAL_DIR" ]; then
      out="$out$name=$value "
    fi
    rest=${rest# }
  done
  printf '%s' "$out"
}

preserved_env() {
  local existing
  existing=$(existing_command "$1" "$2" "$3")
  [ -n "$existing" ] || return 0
  parse_env_prefix "$existing" foreign
}

# The journal directory a previous install wired into this settings file, as a
# path relative to the repository root, or empty when the default is in use.
configured_sessions_dir() {
  local existing
  existing=$(existing_command "$1" "$2" "$3")
  [ -n "$existing" ] || return 0
  # Matched in place rather than split on spaces: the generated value contains a
  # command substitution, which contains spaces of its own.
  parse_env_prefix "$existing" all \
    | sed -n 's|.*SESSION_JOURNAL_DIR="[^"]*)/\([^"]*\)".*|\1|p' \
    | head -n 1
}

if [ "$UNINSTALL" = true ]; then
  # Refuse before touching anything, so a refusal never leaves a half state.
  # Both files are checked regardless of the runtime flags, because
  # remove_owned_block below strips both regardless of the runtime flags.
  sentinels_balanced "$TARGET/CLAUDE.md" || exit 65
  sentinels_balanced "$TARGET/AGENTS.md" || exit 65
  remove_hooks "$CLAUDE_SETTINGS"
  remove_hooks "$CODEX_SETTINGS"
  rm -f "$TARGET/.claude/hooks/session-journal-pointer.sh" "$TARGET/.claude/hooks/session-journal-nudge.sh"
  remove_owned_block "$TARGET/CLAUDE.md"
  remove_owned_block "$TARGET/AGENTS.md"
  echo "Session-journal hooks and instruction blocks removed. Journals, their README, and TEMPLATE.md were kept as project history."
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight. Every refusal happens here, before the first byte is written: the
# installer used to copy both hooks and merge them live into settings.json and
# THEN exit 65 on an unmatched sentinel, leaving enforcement wired up with no
# instruction block to explain it, plus a stray .tmp file in the repository.
# ---------------------------------------------------------------------------

[ "$INSTALL_CLAUDE" = false ] || validate_json_file "$CLAUDE_SETTINGS"
[ "$INSTALL_CODEX" = false ] || validate_json_file "$CODEX_SETTINGS"
[ "$INSTALL_CLAUDE" = false ] || sentinels_balanced "$TARGET/CLAUDE.md" || exit 65
[ "$INSTALL_CODEX" = false ] || sentinels_balanced "$TARGET/AGENTS.md" || exit 65

# The installed hook commands resolve their own root at runtime with
# `git rev-parse --show-toplevel`. Installing into a subdirectory of a git repo
# therefore writes a command that points at a path which does not exist, and the
# hooks fail silently forever. Catch it here instead.
if GIT_TOPLEVEL=$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null); then
  GIT_TOPLEVEL=$(cd "$GIT_TOPLEVEL" && pwd -P)
  if [ "$GIT_TOPLEVEL" != "$TARGET_REAL" ]; then
    echo "$TARGET is inside a git repository but is not its root ($GIT_TOPLEVEL)." >&2
    echo "The installed hooks resolve their root with 'git rev-parse --show-toplevel' at runtime, so they would look for themselves in the wrong place. Install into the repository root instead." >&2
    exit 65
  fi
else
  echo "Note: $TARGET is not a git repository. The hook commands fall back to the agent's working directory at runtime; start the agent from the repository root." >&2
fi

# A rerun without --sessions-dir must not silently relocate the journal
# directory. Rebuilding the command from the default orphaned every existing
# journal -- the hooks began pointing at an empty `sessions/` while the real
# history sat unreachable in `docs/sessions/` -- and reported success.
if [ "$SESSIONS_REL_EXPLICIT" = false ]; then
  for candidate_settings in "$CLAUDE_SETTINGS" "$CODEX_SETTINGS"; do
    [ -e "$candidate_settings" ] || continue
    existing_dir=$(configured_sessions_dir "$candidate_settings" Stop session-journal-nudge.sh)
    [ -n "$existing_dir" ] || existing_dir=$(configured_sessions_dir "$candidate_settings" SessionStart session-journal-pointer.sh)
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

install_hook_script() {
  local name=$1
  sed "s|<VERSION>|$VERSION|" "$SOURCE/hooks/$name" > "$TARGET/.claude/hooks/$name"
  chmod +x "$TARGET/.claude/hooks/$name"
}
install_hook_script session-journal-pointer.sh
install_hook_script session-journal-nudge.sh

# The sessions README is the adopting agent's artifact: ADOPT.md spends its
# question budget adapting it to the repository. Regenerating it on every run
# made the only available upgrade path silently revert that work.
if [ -e "$SESSIONS_ABS/README.md" ] && [ "$REFRESH_DOCS" = false ]; then
  echo "Kept the existing $SESSIONS_REL/README.md (re-run with --refresh-docs to regenerate it)."
else
  render_template "$SOURCE/templates/sessions-README.md" > "$SESSIONS_ABS/README.md"
fi

# Ship the journal shape itself. Without this, both the pointer hook and the
# generated README told a fresh agent to start from a template that the
# installer never placed, so every first journal was written from memory.
if [ -e "$SESSIONS_ABS/TEMPLATE.md" ] && [ "$REFRESH_DOCS" = false ]; then
  echo "Kept the existing $SESSIONS_REL/TEMPLATE.md (re-run with --refresh-docs to regenerate it)."
else
  render_template "$SOURCE/templates/session-journal.md" > "$SESSIONS_ABS/TEMPLATE.md"
fi

RUNTIME_ROOT="\$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
GENERATED_PREFIX=""
[ "$SESSIONS_REL" = "sessions" ] || GENERATED_PREFIX="SESSION_JOURNAL_DIR=\"$RUNTIME_ROOT/$SESSIONS_REL\" "

merge_hooks() {
  local file=$1 runtime=$2 start_matcher="*"
  [ "$runtime" = "codex" ] && start_matcher="startup|resume|clear|compact"
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || printf '%s\n' '{}' > "$file"

  local pointer_env nudge_env pointer_command nudge_command
  pointer_env=$(preserved_env "$file" SessionStart session-journal-pointer.sh)
  nudge_env=$(preserved_env "$file" Stop session-journal-nudge.sh)
  [ -z "$pointer_env" ] || echo "Preserved environment overrides on the SessionStart command: $pointer_env"
  [ -z "$nudge_env" ] || echo "Preserved environment overrides on the Stop command: $nudge_env"
  pointer_command="${pointer_env}${GENERATED_PREFIX}\"$RUNTIME_ROOT/.claude/hooks/session-journal-pointer.sh\""
  nudge_command="${nudge_env}${GENERATED_PREFIX}\"$RUNTIME_ROOT/.claude/hooks/session-journal-nudge.sh\""

  local tmp="$file.session-journal.tmp"
  jq --arg pointer "$pointer_command" --arg nudge "$nudge_command" --arg matcher "$start_matcher" '
    .hooks = (.hooks // {})
    | .hooks.SessionStart = ([.hooks.SessionStart[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-pointer.sh")) | not)] + [{matcher:$matcher,hooks:[{type:"command",command:$pointer}]}])
    | .hooks.Stop = ([.hooks.Stop[]? | select((.hooks // [] | map(.command // "") | join(" ") | contains("session-journal-nudge.sh")) | not)] + [{hooks:[{type:"command",command:$nudge}]}])
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ "$INSTALL_CLAUDE" = true ]; then
  merge_hooks "$CLAUDE_SETTINGS" claude
  replace_owned_block "$TARGET/CLAUDE.md" "$SOURCE/templates/CLAUDE.md-section.md" CLAUDE.md
fi
if [ "$INSTALL_CODEX" = true ]; then
  merge_hooks "$CODEX_SETTINGS" codex
  replace_owned_block "$TARGET/AGENTS.md" "$SOURCE/templates/AGENTS.md-section.md" AGENTS.md
fi

echo "Session journal $VERSION installed at $SESSIONS_REL/. Run the verification steps in ADOPT.md Phase C, or ./doctor.sh $TARGET, before relying on it."
if [ "$INSTALL_CODEX" = true ]; then
  echo "Codex: trust this project and review the new hook definitions with /hooks before expecting them to run."
fi
