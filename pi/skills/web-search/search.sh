#!/usr/bin/env bash
# Keyless web search: Brave (auto-retry with backoff) then DuckDuckGo Lite.
# Usage: search.sh "query" [accept-language]
# SEARCH_ENGINES="brave,ddg" (default) — comma list, tried in order, stops at first results.
# SEARCH_HOPS="direct" (default) — comma list of exits tried in order: direct | ip:ADDR
#   (bind source) | proxy URL (socks5h://host:port, http://host:port). Rotation beats
#   waiting: challenged exits are retried after one short pause, not on a growing backoff.
# stdout: title<TAB>url<TAB>snippet per result. stderr: attempt progress.
# Exit: 0 = results; 2 = engines still challenged or network down (back off minutes);
#       3 = no results parsed from any engine (markup changed?).
#
# 2026-11-15: Brave rate-limits the 2nd/3rd rapid hit from one IP with a 200+challenge
# page. Verified then: this exact request shape (source=web, this UA) is fine — only the
# timing differed. Both parsers were written from captured payloads of that day; note
# DDG Lite uses single-quoted class='result-link' / class='result-snippet' and
# &amp;-separated, percent-encoded uddg= targets.
set -euo pipefail
q="${1:?usage: search.sh \"query\" [lang]}"
lang="${2:-en-US}"
ua="Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
brave_url="https://search.brave.com/search"
ddg_url="https://lite.duckduckgo.com/lite/"
tmp="$(mktemp /tmp/websearch.XXXXXX.html)"
trap 'rm -f "$tmp"' EXIT

clean() { sed -E "s/<[^>]+>/ /g;s/&#x27;|&#039;|&#8217;|&#8216;/'/g;s/&amp;/\&/g;s/&quot;/\"/g;s/&nbsp;/ /g;s/&lt;/</g;s/&gt;/>/g;s/[[:space:]]+/ /g"; }
trim()   { sed -E 's/[[:space:]]+/ /g;s/^ //;s/ $//'; }
urldecode() { printf '%b' "$(sed -E 's/%/\\x/g' <<<"$1")" | tr '\t\n' '  '; }

# --- parsers: pure, html on stdin -> title<TAB>url<TAB>snippet on stdout ------------------
parse_brave() {
  tr '\n' ' ' | sed 's/<div class="snippet/\n&/g' | tail -n +2 | while IFS= read -r blk; do
    url=$(grep -oE 'href="https?://[^"]+"' <<<"$blk" | head -1 | sed 's/href="//;s/"$//;s/[[:space:]]//g' || true)
    [ -n "$url" ] || continue
    title=$(grep -oE 'class="title[^"]*"[^>]*>[^<]+' <<<"$blk" | head -1 | sed 's/.*>//' | trim || true)
    printf '%s\t%s\t%s\n' "${title:-?}" "$url" "$(clean <<<"$blk" | cut -c1-400)"
  done
}

parse_ddg() {
  # collapse first: while-read would otherwise end each block at the next physical line
  tr '\n' ' ' | sed -E 's#(<a rel="nofollow" href="//duckduckgo\.com/l/\?uddg=)#\n\1#g' | tail -n +2 |
  while IFS= read -r blk; do
    enc=$(grep -oE 'uddg=[^&"]+' <<<"$blk" | head -1 | sed -E 's/^uddg=//;s/[[:space:]]//g' || true)
    [ -n "$enc" ] || continue
    url=$(urldecode "$enc")
    title=$(grep -oE "class='result-link'>[^<]+" <<<"$blk" | head -1 | sed 's/.*>//' | trim || true)
    snip=$(sed -nE "s/.*class='result-snippet'>//p" <<<"$blk" | sed -E 's#</td>.*##' | clean | cut -c1-400 || true)
    printf '%s\t%s\t%s\n' "${title:-?}" "$url" "$snip"
  done
}

# --- acquisition: the imperative shell -----------------------------------------------------
hops="${SEARCH_HOPS:-direct}"
curl_hop=()   # set by hop_arg for the current exit

hop_arg() { # $1 = hop spec; fills curl_hop for fetch, or returns 1 for an unknown hop.
  case "$1" in
  direct)                                                curl_hop=() ;;
  ip:*)                                                  curl_hop=(--interface "${1#ip:}") ;;
  socks5h://*|socks5://*|socks4://*|http://*|https://*)  curl_hop=(--proxy "$1") ;;
  *) echo "unknown hop: $1" >&2; return 1 ;;
  esac
}

fetch() { # $1 = url; remaining args: extra query params. Writes the page to $tmp.
  curl -sfL -m 20 -A "$ua" -H "Accept-Language: $lang,en;q=0.8" "${curl_hop[@]}" -G "$1" -o "$tmp" "${@:2}"
}

engines="${SEARCH_ENGINES:-brave,ddg}"
saw_challenge=0; got=0
for eng in ${engines//,/ }; do
  case "$eng" in
  brave)
    for pass in 1 2; do
      for hop in ${hops//,/ }; do
        hop_arg "$hop" || continue
        if ! fetch "$brave_url" --data-urlencode "q=$q" --data-urlencode "source=web"; then
          echo "brave: fetch failed [$hop] (pass $pass/2)" >&2; saw_challenge=1
        elif results=$(parse_brave <"$tmp" || true) && [ -n "$results" ]; then
          printf '%s\n' "$results"; got=1; break 3   # leave the engine loop too: ddg is not needed
        elif grep -qiE 'captcha|are you a robot' "$tmp"; then
          echo "brave: challenge [$hop] (pass $pass/2)" >&2; saw_challenge=1
        else
          echo "brave: 0 results parsed [$hop] (markup changed?)" >&2; break 2   # markup won't heal on another exit
        fi
      done
      if [ "$pass" -lt 2 ]; then d=$((8 + RANDOM % 8)); echo "brave: all exits challenged; retry in ${d}s" >&2; sleep "$d"; fi
    done
    ;;
  ddg)
    for hop in ${hops//,/ }; do
      hop_arg "$hop" || continue
      if fetch "$ddg_url" --data-urlencode "q=$q" \
         && results=$(parse_ddg <"$tmp" || true) && [ -n "$results" ]; then
        printf '%s\n' "$results"; got=1; break
      fi
      echo "ddg: no results [$hop] (rate-limited or markup changed?)" >&2
    done
    ;;
  *) echo "unknown engine: $eng" >&2; exit 3 ;;
  esac
done

if [ "$got" = 1 ]; then exit 0; fi
if [ "$saw_challenge" = 1 ]; then
  echo "all engines failed; brave kept challenging or died — back off minutes, not seconds" >&2
  exit 2
fi
echo "no results parsed from any engine (markup changed?)" >&2
exit 3
