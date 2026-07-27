#!/usr/bin/env bash
# Close idle Herdr panes in the current (or named) session.
#
# Idle means:
#   - no agent harness is open on the pane (claude / codex / opencode / pi / grok, etc.)
#   - no vim / nvim / vi editor is in the foreground
#   - the foreground process is a shell (zsh / bash / sh / fish / dash) or empty
#
# Usage:
#   fm-herdr-close-idle-panels.sh              # close all idle panes
#   fm-herdr-close-idle-panels.sh --dry-run    # list only
#   fm-herdr-close-idle-panels.sh --include-focused
#   fm-herdr-close-idle-panels.sh --session <name>
#   fm-herdr-close-idle-panels.sh --json       # machine-readable summary
#
# Safety:
#   - Never closes the focused pane unless --include-focused is set
#   - Never closes a pane that reports a non-empty herdr "agent" label
#   - Never closes a pane whose foreground process looks like a harness or editor
#   - Does not kill firstmate tasks' metadata; only closes Herdr panes
set -euo pipefail

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

DRY_RUN=0
INCLUDE_FOCUSED=0
JSON_OUT=0
SESSION="${HERDR_SESSION:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run|-n) DRY_RUN=1; shift ;;
    --include-focused) INCLUDE_FOCUSED=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --session) SESSION=${2:-}; shift 2 ;;
    --session=*) SESSION=${1#--session=}; shift ;;
    -h|--help) usage 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage 2
      ;;
  esac
done

if ! command -v herdr >/dev/null 2>&1; then
  echo "error: herdr CLI not found on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 1
fi

herdr_cli() {
  if [[ -n "$SESSION" ]]; then
    HERDR_SESSION="$SESSION" herdr "$@" --session "$SESSION"
  else
    herdr "$@"
  fi
}

# Returns 0 if this process name/cmdline looks like a verified agent harness.
is_harness_process() {
  local name=$1 cmdline=$2 argv0=$3
  local n c a base
  n=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  c=$(printf '%s' "$cmdline" | tr '[:upper:]' '[:lower:]')
  a=$(printf '%s' "$argv0" | tr '[:upper:]' '[:lower:]')
  base=$(basename "$a" 2>/dev/null || printf '%s' "$a")

  case "$n" in
    claude*|codex*|opencode*|grok*|pi) return 0 ;;
  esac
  case "$base" in
    claude|claude-code|codex|opencode|grok|grok-*|pi) return 0 ;;
  esac
  case "$c" in
    claude\ *|claude|*claude-code*|codex\ *|*codex*|opencode\ *|*opencode*|grok\ *|*grok*)
      return 0
      ;;
  esac
  # bare pi as first argv token only (avoid matching paths that contain "pi")
  case "$c" in
    pi|pi\ *) return 0 ;;
  esac
  [[ "$n" == "pi" || "$base" == "pi" ]] && return 0
  return 1
}

is_editor_process() {
  local name=$1 cmdline=$2 argv0=$3
  local base
  base=$(basename "$argv0" 2>/dev/null || printf '%s' "$argv0")
  case "$name" in
    vim|nvim|vi|view|vimdiff|nvim-* ) return 0 ;;
  esac
  case "$base" in
    vim|nvim|vi|view|vimdiff) return 0 ;;
  esac
  case "$cmdline" in
    vim\ *|nvim\ *|vi\ *|view\ *|vimdiff\ *) return 0 ;;
  esac
  return 1
}

is_shell_process() {
  local name=$1 argv0=$2
  local base
  base=$(basename "$argv0" 2>/dev/null || printf '%s' "$argv0")
  case "$name" in
    zsh|bash|sh|fish|dash|csh|tcsh) return 0 ;;
  esac
  case "$base" in
    zsh|bash|sh|fish|dash|-zsh|-bash|csh|tcsh) return 0 ;;
  esac
  # login shells often report argv0 as -zsh
  case "$argv0" in
    -zsh|-bash|-sh|-fish) return 0 ;;
  esac
  return 1
}

list_json=$(herdr_cli pane list 2>/dev/null) || {
  echo "error: herdr pane list failed (is the server running?)" >&2
  exit 1
}

mapfile -t PANE_IDS < <(printf '%s' "$list_json" | jq -r '.result.panes[]?.pane_id // empty')

closed=()
kept=()
errors=()

for pane_id in "${PANE_IDS[@]}"; do
  [[ -z "$pane_id" ]] && continue

  meta=$(printf '%s' "$list_json" | jq -c --arg id "$pane_id" '.result.panes[] | select(.pane_id == $id)')
  agent=$(printf '%s' "$meta" | jq -r '.agent // empty')
  agent_status=$(printf '%s' "$meta" | jq -r '.agent_status // empty')
  focused=$(printf '%s' "$meta" | jq -r '.focused // false')
  cwd=$(printf '%s' "$meta" | jq -r '.cwd // .foreground_cwd // empty')
  tab_id=$(printf '%s' "$meta" | jq -r '.tab_id // empty')

  reason=""

  if [[ "$focused" == "true" && "$INCLUDE_FOCUSED" -eq 0 ]]; then
    reason="focused (use --include-focused to allow)"
  elif [[ -n "$agent" ]]; then
    reason="agent harness open: ${agent} (${agent_status:-unknown})"
  else
    pinfo=$(herdr_cli pane process-info --pane "$pane_id" 2>/dev/null) || {
      reason="process-info failed"
      kept+=("$pane_id|$reason|$cwd|$tab_id")
      continue
    }
    # Inspect each foreground process
    while IFS=$'\t' read -r name cmdline argv0; do
      [[ -z "${name:-}" && -z "${cmdline:-}" && -z "${argv0:-}" ]] && continue
      if is_harness_process "$name" "$cmdline" "$argv0"; then
        reason="harness process: ${name:-$argv0}"
        break
      fi
      if is_editor_process "$name" "$cmdline" "$argv0"; then
        reason="editor open: ${name:-$argv0}"
        break
      fi
    done < <(printf '%s' "$pinfo" | jq -r '
      .result.process_info.foreground_processes[]?
      | [(.name // ""), (.cmdline // ""), (.argv0 // "")]
      | @tsv
    ')

    if [[ -z "$reason" ]]; then
      # Require every foreground process to be a shell (or no processes)
      non_shell=0
      while IFS=$'\t' read -r name cmdline argv0; do
        [[ -z "${name:-}" && -z "${argv0:-}" ]] && continue
        if ! is_shell_process "$name" "$argv0"; then
          non_shell=1
          reason="non-shell process: ${name:-$argv0}"
          break
        fi
      done < <(printf '%s' "$pinfo" | jq -r '
        .result.process_info.foreground_processes[]?
        | [(.name // ""), (.cmdline // ""), (.argv0 // "")]
        | @tsv
      ')
      if [[ "$non_shell" -eq 0 && -z "$reason" ]]; then
        reason="" # idle
      fi
    fi
  fi

  if [[ -n "$reason" ]]; then
    kept+=("$pane_id|$reason|$cwd|$tab_id")
    continue
  fi

  # Idle → close (or dry-run)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    closed+=("$pane_id|dry-run|$cwd|$tab_id")
    continue
  fi

  if herdr_cli pane close "$pane_id" >/dev/null 2>&1; then
    closed+=("$pane_id|closed|$cwd|$tab_id")
  else
    errors+=("$pane_id|close failed|$cwd|$tab_id")
  fi
done

if [[ "$JSON_OUT" -eq 1 ]]; then
  jq -n \
    --arg session "${SESSION:-default}" \
    --argjson dry "$DRY_RUN" \
    --argjson closed "$(printf '%s\n' "${closed[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0)|split("|")|{pane_id:.[0],action:.[1],cwd:.[2],tab_id:.[3]})')" \
    --argjson kept "$(printf '%s\n' "${kept[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0)|split("|")|{pane_id:.[0],reason:.[1],cwd:.[2],tab_id:.[3]})')" \
    --argjson errors "$(printf '%s\n' "${errors[@]:-}" | jq -R -s -c 'split("\n")|map(select(length>0)|split("|")|{pane_id:.[0],error:.[1],cwd:.[2],tab_id:.[3]})')" \
    '{session:$session, dry_run:($dry==1), closed:$closed, kept:$kept, errors:$errors,
      counts:{closed:($closed|length), kept:($kept|length), errors:($errors|length)}}'
  exit 0
fi

echo "session: ${SESSION:-default (implicit)}"
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "mode: dry-run (no panes closed)"
else
  echo "mode: close idle panes"
fi
echo

if [[ ${#closed[@]} -gt 0 ]]; then
  echo "idle (${#closed[@]}):"
  for row in "${closed[@]}"; do
    IFS='|' read -r id action cwd tab <<<"$row"
    echo "  $id  [$action]  tab=$tab  cwd=${cwd:-?}"
  done
  echo
else
  echo "idle: none"
  echo
fi

if [[ ${#kept[@]} -gt 0 ]]; then
  echo "kept (${#kept[@]}):"
  for row in "${kept[@]}"; do
    IFS='|' read -r id reason cwd tab <<<"$row"
    echo "  $id  $reason  tab=$tab"
  done
  echo
fi

if [[ ${#errors[@]} -gt 0 ]]; then
  echo "errors (${#errors[@]}):" >&2
  for row in "${errors[@]}"; do
    IFS='|' read -r id err cwd tab <<<"$row"
    echo "  $id  $err" >&2
  done
  exit 1
fi
