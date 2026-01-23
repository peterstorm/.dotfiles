#!/bin/bash
# Cross-platform file locking helper
# Uses flock on Linux, mkdir-based locking on macOS
#
# Usage:
#   source ~/.claude/hooks/helpers/lock.sh
#   acquire_lock "lockfile"
#   # ... do work ...
#   release_lock "lockfile"
#
# Or for automatic release on exit:
#   source ~/.claude/hooks/helpers/lock.sh
#   acquire_lock "lockfile" auto
#   # lock released when script exits

LOCK_FD=200
_CURRENT_LOCK=""

acquire_lock() {
  local lock_file="$1"
  local auto_release="${2:-}"

  # Use flock if available (Linux)
  if command -v flock &>/dev/null; then
    eval "exec $LOCK_FD>\"$lock_file\""
    flock -x $LOCK_FD
  else
    # macOS: use mkdir (atomic operation)
    local lock_dir="${lock_file}.lock"
    local max_attempts=50
    local attempt=0

    while ! mkdir "$lock_dir" 2>/dev/null; do
      ((attempt++))
      if [[ $attempt -ge $max_attempts ]]; then
        echo "ERROR: Could not acquire lock after $max_attempts attempts" >&2
        return 1
      fi
      sleep 0.1
    done

    # Store lock info for cleanup
    echo $$ > "$lock_dir/pid"
  fi

  _CURRENT_LOCK="$lock_file"

  # Auto-release on exit if requested
  if [[ "$auto_release" == "auto" ]]; then
    trap 'release_lock "$_CURRENT_LOCK"' EXIT
  fi
}

release_lock() {
  local lock_file="$1"

  if command -v flock &>/dev/null; then
    eval "exec $LOCK_FD>&-" 2>/dev/null || true
  else
    rm -rf "${lock_file}.lock" 2>/dev/null || true
  fi

  _CURRENT_LOCK=""
}
