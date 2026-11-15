---
name: web-search
description: Search the web without an API key via Brave Search's HTML endpoint (auto-retry + DuckDuckGo Lite fallback), and fetch page text. Use for prices, deals, news, docs lookups, or any question needing live web data. Pi has no built-in web search; this is it.
---

# web-search

Pi has no built-in web search. This skill scrapes keyless, public, HTML search endpoints.
Brave Search is primary. When Brave rate-limits — it challenged or 429'd the 2nd/3rd rapid
hit from one IP (verified 2026-11-15) — `search.sh` now rides it out itself: two passes over
the configured exits (default: just this host) with one short pause between them, then
DuckDuckGo Lite as rescue.

## Usage

```bash
# Search: prints "title<TAB>url<TAB>snippet" per result. Exit 0 = results.
# Usually <30s; up to ~1min if every exit is challenged. Pass a generous timeout.
~/.dotfiles/pi/skills/web-search/search.sh "samsung 9100 pro 2tb pris" [da-DK]

# Skip Brave entirely (e.g. when it 429s hard late in a long session):
SEARCH_ENGINES=ddg ~/.dotfiles/pi/skills/web-search/search.sh "query"

# Engines: SEARCH_ENGINES="brave,ddg" (default) — comma list, tried in order, stops at the
# first engine that returns results. Space the search calls a few seconds apart if you can.

# Rotate exits instead of waiting (at home — the SOCKS hop rides the transmission NordVPN
# tunnel, LAN-reachable; see k8s/argocd-homelab/transmission/):
SEARCH_HOPS="direct,socks5h://192.168.0.29:1080" ~/.dotfiles/pi/skills/web-search/search.sh "query"
# Hops: direct | ip:ADDR (bind a source address) | socks5h://… | http://… — comma list,
# tried in order each pass. Default "direct". Off the LAN, drop the socks hop.

# Fetch a page as plain text (default first 6000 chars)
~/.dotfiles/pi/skills/web-search/fetch.sh "https://example.com/article" [max-chars]
```

## Exit codes

- **0** — results (whichever engine managed it; stderr says who)
- **2** — every engine exhausted: challenge/network persisted through all retries. Back off
  **minutes**, not seconds — or just rerun with `SEARCH_ENGINES=ddg`.
- **3** — every engine answered 200 but nothing parsed (markup changed). Capture the HTML
  and re-derive the parsers from the real payload — don't guess.

## Gotchas

- Verified 2026-11-15: DuckDuckGo **Lite** (`lite.duckduckgo.com`) answers from the homelab
  IP (single-quoted `class='result-link'` markup, &amp;-separated %-encoded `uddg=` targets —
  the script unwraps them to the real URLs). Mojeek serves a JS challenge to curl: unusable.
- IPv6 source rotation is dead on this box: all six global addresses sit in one /64
  (2a05:f6c3:9dbf:0::/64), and Brave buckets per-prefix — three different source addresses
  got 200, 429, 429 within 2s (verified 2026-11-15).
- The NordVPN exit (transmission pod) is a different IP (187.15.110.81 vs the household
  90.184.68.248) but a shared one: Brave 429s from there too, while DuckDuckGo Lite answers
  (202). Useful as a DDG rescue hop, not a Brave fix.
- Shop sites block the homelab IP (Pricerunner 403, Prisjagt/Proshop Cloudflare,
  Komplett/Amazon/Samsung DK connection errors). Search results and review/deal-site
  articles (9to5toys, pcguide, tomshardware) fetch fine; retailer pages mostly don't.
- Deal articles go stale fast — compare the article date with `date +%F`.
