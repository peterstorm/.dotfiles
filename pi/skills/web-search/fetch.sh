#!/usr/bin/env bash
# Fetch a URL as plain text. Usage: fetch.sh URL [max-chars]
set -eu
url="${1:?usage: fetch.sh URL [max-chars]}"
max="${2:-6000}"
ua="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"

body=$(curl -sfL -m 25 -A "$ua" "$url")
# Drop script/style blocks line-wise (never greedy across the page), then strip tags.
printf '%s\n' "$body" \
  | sed -E '/<(script|style|noscript)[^>]*>/,/<\/(script|style|noscript)>/d' \
  | sed -E 's/<[^>]+>/\n/g' \
  | sed -E "s/&#8217;|&#039;|&#x27;/'/g;s/&amp;/\&/g;s/^[[:space:]]+//;s/[[:space:]]+\$//" \
  | grep -v '^$' | head -c "$max" || true
