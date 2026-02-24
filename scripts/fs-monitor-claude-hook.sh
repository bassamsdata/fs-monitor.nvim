#!/usr/bin/env bash
# fs-monitor-claude-hook.sh
# Claude Code hook script for fs-monitor.nvim
# Logs to /tmp/fs-monitor-claude.log for debugging.
#
# NVIM_FSMONITOR_ADDR is injected by install_hooks() and points to the
# exact Neovim instance that owns the monitoring session.

set -uo pipefail

LOG="/tmp/fs-monitor-claude.log"

log() {
  echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"
}

log "=== Hook invoked ==="

# Read JSON input from stdin
INPUT=$(cat)

# --- JSON parsing ---
# Extract a top-level string value: json_val '{"key":"value"}' key → value
json_val() {
  # Matches "key": "value" or "key":"value" — handles escaped quotes
  echo "$1" | grep -o "\"$2\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//'
}

EVENT=$(json_val "$INPUT" "hook_event_name")
log "Event: $EVENT"

# The Neovim server address — set by install_hooks()
NVIM_ADDR="${NVIM_FSMONITOR_ADDR:-${NVIM_LISTEN_ADDRESS:-}}"

if [ -z "$NVIM_ADDR" ]; then
  log "ERROR: NVIM_FSMONITOR_ADDR not set"
  exit 0
fi

send_rpc() {
  local expr="$1"
  RESULT=$(nvim --server "$NVIM_ADDR" --remote-expr "$expr" 2>&1) && {
    log "RPC OK: $RESULT"
    return 0
  }
  log "RPC FAIL: $RESULT"
  return 1
}

escape_lua() {
  echo "$1" | sed "s/'/\\\\'/g"
}

case "$EVENT" in
  PreToolUse)
    TOOL_NAME=$(json_val "$INPUT" "tool_name")
    TOOL_NAME="${TOOL_NAME:-unknown}"
    log "PreToolUse: tool=$TOOL_NAME"
    TOOL_ESCAPED=$(escape_lua "$TOOL_NAME")
    send_rpc "v:lua.require('fs-monitor.adapters.claude')._on_pre_tool_use('${TOOL_ESCAPED}')"
    ;;
  PostToolUse)
    FILE_PATH=$(json_val "$INPUT" "file_path")
    TOOL_NAME=$(json_val "$INPUT" "tool_name")
    TOOL_NAME="${TOOL_NAME:-unknown}"
    log "PostToolUse: tool=$TOOL_NAME file=${FILE_PATH:-<none>}"
    if [ -n "$FILE_PATH" ]; then
      FILE_PATH_ESCAPED=$(escape_lua "$FILE_PATH")
      TOOL_ESCAPED=$(escape_lua "$TOOL_NAME")
      send_rpc "v:lua.require('fs-monitor.adapters.claude')._on_file_changed('${FILE_PATH_ESCAPED}','${TOOL_ESCAPED}')"
    else
      log "No file_path (tool=$TOOL_NAME), watcher catches changes"
    fi
    ;;
  Stop|SessionEnd)
    log "Stop/SessionEnd"
    send_rpc "v:lua.require('fs-monitor.adapters.claude')._on_session_end()"
    ;;
  SessionStart)
    log "SessionStart"
    send_rpc "v:lua.require('fs-monitor.adapters.claude')._on_session_start()"
    ;;
  *)
    log "Unhandled event: $EVENT"
    ;;
esac

log "=== Done ==="
exit 0
