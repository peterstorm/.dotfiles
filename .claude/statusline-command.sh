#!/bin/bash
# Claude Code status line — context + tokens
input=$(cat)

# Context window
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
win_size=$(echo "$input" | jq -r '(.context_window.context_window_size // 0) | tonumber')

# Current request tokens (input = raw + cache_read + cache_create)
raw_in=$(echo "$input" | jq -r '(.context_window.current_usage.input_tokens // 0) | tonumber')
cache_read=$(echo "$input" | jq -r '(.context_window.current_usage.cache_read_input_tokens // 0) | tonumber')
cache_create=$(echo "$input" | jq -r '(.context_window.current_usage.cache_creation_input_tokens // 0) | tonumber')
cur_out=$(echo "$input" | jq -r '(.context_window.current_usage.output_tokens // 0) | tonumber')

# Total = all input sources combined
total_in=$(( raw_in + cache_read + cache_create ))

# Session cumulative
sess_in=$(echo "$input" | jq -r '(.context_window.total_input_tokens // 0) | tonumber')
sess_out=$(echo "$input" | jq -r '(.context_window.total_output_tokens // 0) | tonumber')

# Model
model=$(echo "$input" | jq -r '.model.display_name // "?"' | sed 's/Claude //' | sed 's/ Sonnet/S/' | sed 's/ Opus/O/' | sed 's/ Haiku/H/')

# Git
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
git_branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  git_branch=$(git -C "$cwd" branch --show-current 2>/dev/null || echo "detached")
  git -C "$cwd" diff-index --quiet HEAD -- 2>/dev/null || git_branch="${git_branch}*"
fi

parts=()

# Context % (color-coded)
if [ -n "$used_pct" ]; then
  pct_int=${used_pct%.*}
  if [ "${pct_int:-0}" -gt 80 ]; then c='\033[31m'
  elif [ "${pct_int:-0}" -gt 60 ]; then c='\033[33m'
  else c='\033[32m'; fi
  win_k=$((win_size / 1000))
  in_k=$((total_in / 1000))
  parts+=("$(printf "${c}%dK/%dK (%.0f%%)\033[0m" "$in_k" "$win_k" "$used_pct")")
fi

# Output tokens (current request)
if [ "${cur_out:-0}" -gt 0 ] 2>/dev/null; then
  out_k=$((cur_out / 1000))
  parts+=("$(printf '\033[2mout:%dK\033[0m' "$out_k")")
fi

# Session totals
if [ "${sess_in:-0}" -gt 0 ] 2>/dev/null; then
  si_k=$((sess_in / 1000))
  so_k=$((sess_out / 1000))
  parts+=("$(printf '\033[2msess:%dK↓%dK↑\033[0m' "$si_k" "$so_k")")
fi

# Cache hit ratio
cache_total=$((cache_read + cache_create))
if [ "$cache_total" -gt 0 ] 2>/dev/null; then
  hit_pct=$((cache_read * 100 / cache_total))
  parts+=("$(printf '\033[36mcache:%d%%\033[0m' "$hit_pct")")
fi

# Model
parts+=("$(printf '\033[2m%s\033[0m' "$model")")

# Git branch
[ -n "$git_branch" ] && parts+=("$(printf '\033[33m%s\033[0m' "$git_branch")")

IFS=' · '
printf "%s\n" "${parts[*]}"
