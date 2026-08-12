#!/bin/bash
# Statusline: Model | dir@branch (+a -d) | tokens (pct) | effort | 5h pct @reset | 7d pct @reset
# All data comes from the statusline stdin JSON (schema: https://code.claude.com/docs/en/statusline).
# Rate limits (Pro/Max) arrive in .rate_limits — no API calls needed.

set -f  # disable globbing

input=$(cat)

if [ -z "$input" ]; then
    printf "Claude"
    exit 0
fi

# ANSI colors matching oh-my-posh theme
blue='\033[38;2;0;153;255m'
orange='\033[38;2;255;176;85m'
green='\033[38;2;0;160;0m'
cyan='\033[38;2;46;149;153m'
red='\033[38;2;255;85;85m'
yellow='\033[38;2;230;200;0m'
white='\033[38;2;220;220;220m'
dim='\033[2m'
reset='\033[0m'

# Format token counts (e.g., 50k / 200k)
format_tokens() {
    local num=$1
    if [ "$num" -ge 1000000 ]; then
        awk "BEGIN {printf \"%.1fm\", $num / 1000000}"
    elif [ "$num" -ge 1000 ]; then
        awk "BEGIN {printf \"%.0fk\", $num / 1000}"
    else
        printf "%d" "$num"
    fi
}

# Return color escape based on usage percentage
usage_color() {
    local pct=$1
    if [ "$pct" -ge 90 ]; then echo "$red"
    elif [ "$pct" -ge 70 ]; then echo "$orange"
    elif [ "$pct" -ge 50 ]; then echo "$yellow"
    else echo "$green"
    fi
}

# Format an epoch-seconds timestamp as compact local time.
# Usage: format_reset_time <epoch> <style: time|datetime>
format_reset_time() {
    local epoch="$1" style="$2"
    case "$epoch" in ''|null|*[!0-9]*) return ;; esac
    if [ "$style" = "time" ]; then
        date -d "@$epoch" +"%l:%M%P" 2>/dev/null | sed 's/^ //'
    else
        date -d "@$epoch" +"%b %-d, %l:%M%P" 2>/dev/null | sed 's/  / /g; s/^ //'
    fi
}

# ===== Extract data from JSON =====
model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')

# Context window
size=$(echo "$input" | jq -r '.context_window.context_window_size // 200000')
case "$size" in ''|null|0|*[!0-9]*) size=200000 ;; esac

input_tokens=$(echo "$input" | jq -r '.context_window.current_usage.input_tokens // 0')
cache_create=$(echo "$input" | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input" | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
current=$(( input_tokens + cache_create + cache_read ))

used_tokens=$(format_tokens "$current")
total_tokens=$(format_tokens "$size")

# Prefer the precomputed percentage; fall back to computing it
pct_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
case "$pct_used" in
    ''|null) pct_used=$(( current * 100 / size )) ;;
    *) pct_used=$(printf '%.0f' "$pct_used" 2>/dev/null || echo 0) ;;
esac

# Reasoning effort
effort_level="${CLAUDE_CODE_EFFORT_LEVEL:-}"
if [ -z "$effort_level" ] && [ -f "$HOME/.claude/settings.json" ]; then
    effort_level=$(jq -r '.effortLevel // "high"' "$HOME/.claude/settings.json" 2>/dev/null)
fi
effort_level="${effort_level:-high}"

# ===== Build single-line output =====
out=""
out+="${blue}${model_name}${reset}"

# Current working directory + git branch + churn (staged + unstaged)
cwd=$(echo "$input" | jq -r '.cwd // empty')
if [ -n "$cwd" ]; then
    display_dir="${cwd##*/}"
    git_branch=$(git -C "${cwd}" rev-parse --abbrev-ref HEAD 2>/dev/null)
    out+=" ${dim}|${reset} "
    out+="${cyan}${display_dir}${reset}"
    if [ -n "$git_branch" ]; then
        out+="${dim}@${reset}${green}${git_branch}${reset}"
        git_stat=$( { git -C "${cwd}" diff --numstat; git -C "${cwd}" diff --cached --numstat; } 2>/dev/null \
            | awk '{a+=$1; d+=$2} END {if (a+d>0) printf "+%d -%d", a, d}')
        [ -n "$git_stat" ] && out+=" ${dim}(${reset}${green}${git_stat%% *}${reset} ${red}${git_stat##* }${reset}${dim})${reset}"
    fi
fi

out+=" ${dim}|${reset} "
out+="${orange}${used_tokens}/${total_tokens}${reset} ${dim}(${reset}${green}${pct_used}%${reset}${dim})${reset}"
out+=" ${dim}|${reset} "
out+="effort: "
case "$effort_level" in
    low)    out+="${dim}low${reset}" ;;
    medium) out+="${orange}med${reset}" ;;
    *)      out+="${green}high${reset}" ;;
esac

# ===== Rate limits (from stdin; present for Pro/Max after first API response) =====
sep=" ${dim}|${reset} "

five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_hour_pct" ] && [ "$five_hour_pct" != "null" ]; then
    five_hour_pct=$(printf '%.0f' "$five_hour_pct" 2>/dev/null || echo 0)
    five_hour_reset=$(format_reset_time "$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')" "time")
    five_hour_color=$(usage_color "$five_hour_pct")
    out+="${sep}${white}5h${reset} ${five_hour_color}${five_hour_pct}%${reset}"
    [ -n "$five_hour_reset" ] && out+=" ${dim}@${five_hour_reset}${reset}"
fi

seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$seven_day_pct" ] && [ "$seven_day_pct" != "null" ]; then
    seven_day_pct=$(printf '%.0f' "$seven_day_pct" 2>/dev/null || echo 0)
    seven_day_reset=$(format_reset_time "$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')" "datetime")
    seven_day_color=$(usage_color "$seven_day_pct")
    out+="${sep}${white}7d${reset} ${seven_day_color}${seven_day_pct}%${reset}"
    [ -n "$seven_day_reset" ] && out+=" ${dim}@${seven_day_reset}${reset}"
fi

# Output single line
printf "%b" "$out"

exit 0
