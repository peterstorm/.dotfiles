#!/usr/bin/env python3
"""GitHub-style calendar heatmap of local inference token usage.

Reads the engine-neutral ledger written by vllm-stats-record.py (per-interval token deltas)
and renders a self-contained static HTML page: generation tokens per day as a
GitHub-style contribution calendar, a last-14-days bar list, lifetime stats,
and explainers so the numbers can't be mistaken.

Output (--write):  <VLLM_STATS_DIR>/heatmap/index.html
Summary:           printed to stdout either way.
"""
import argparse
import csv
import datetime as dt
import os
import sys

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_OUT = os.path.join(DIR, "heatmap", "index.html")

WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def fmt(n):
    n = int(n)
    if n >= 1_000_000_000:
        return f"{n / 1e9:.2f}B"
    if n >= 1_000_000:
        return f"{n / 1e6:.1f}M"
    if n >= 1_000:
        return f"{n / 1e3:.0f}K"
    return str(n)


def load(path):
    days = {}  # date -> generation tokens
    if not os.path.exists(path):
        return days
    with open(path, newline="") as f:
        for row in csv.reader(f):
            if not row or row[0] == "ts":
                continue
            try:
                day = dt.date.fromtimestamp(int(row[0]))
                gen = float(row[3] or 0)
            except (ValueError, IndexError):
                continue
            days[day] = days.get(day, 0.0) + gen
    return days


def buckets(nonzero):
    """Quantile-style bins like GitHub: 4 equal-count groups over nonzero days."""
    if not nonzero:
        return [0, 0, 0, 0]
    s = sorted(nonzero)
    n = len(s)
    return [s[n * (i + 1) // 4 - 1] for i in range(4)]


def level_for(value, b):
    if value <= 0:
        return 0
    if value <= b[0]:
        return 1
    if value <= b[1]:
        return 2
    if value <= b[2]:
        return 3
    return 4


def streaks(days):
    active = {d for d, v in days.items() if v > 0}
    if not active:
        return 0, 0
    longest = cur = 1
    prev = sorted(active)[0]
    for d in sorted(active)[1:]:
        cur = cur + 1 if (d - prev).days == 1 else 1
        longest = max(longest, cur)
        prev = d
    cur = 0
    d = max(active)
    while d in active:
        cur += 1
        d -= dt.timedelta(days=1)
    return longest, cur


def legend(cell, step):
    squares = "".join(
        f'<rect class="d" data-level="{i}" x="{i * step}" y="0" '
        f'width="{cell}" height="{cell}" rx="2"></rect>'
        for i in range(5)
    )
    return (f'<span>less</span><svg width="{5 * step}" height="{cell}" '
            f'xmlns="http://www.w3.org/2000/svg">{squares}</svg><span>more</span>')


def bar_rows(days):
    recent = sorted(days.items(), key=lambda kv: kv[0], reverse=True)[:14]
    recent.reverse()
    if not recent:
        return ""
    maxv = max(v for _, v in recent) or 1.0
    rows = []
    for d, v in recent:
        pct = max(2.0, v / maxv * 100)
        rows.append(
            f'<div class="bar-row"><span class="bar-date">{d.strftime("%a %d %b")}</span>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct:.0f}%"></div></div>'
            f'<span class="bar-val">{fmt(v)}</span></div>'
        )
    return "".join(rows)


def render(days, out_path):
    today = dt.date.today()
    oldest = min(days) if days else today
    start = max(oldest, today - dt.timedelta(days=364))
    start -= dt.timedelta(days=start.weekday() + 1)  # back to Sunday
    weeks = []
    d = start
    while d <= today:
        weeks.append([d + dt.timedelta(days=i) for i in range(7)])
        d += dt.timedelta(days=7)

    nonzero = [v for v in days.values() if v > 0]
    b = buckets(nonzero)

    # Adaptive cell size: with very little history a GitHub calendar is
    # meaningless, so use bigger cells — and always pair it with the bar list.
    cell = 11 if len(weeks) >= 26 else 16
    gap = 2 if cell == 11 else 4
    step = cell + gap
    svg_w = len(weeks) * step + 40

    rows = csv_rows()
    total_gen = int(sum(days.values()))
    total_prompt = int(sum(float(r[2] or 0) for r in rows))
    total_req = int(sum(float(r[4] or 0) for r in rows))
    timestamped_rows = [r for r in rows if len(r) > 1 and r[0].isdigit()]
    latest_row = max(timestamped_rows, key=lambda row: int(row[0])) if timestamped_rows else None
    # Use the ledger's recorded local-time text rather than the renderer's
    # timezone; containerized one-off renders may otherwise display UTC.
    last_recorded = latest_row[1] if latest_row else "never"
    last7 = int(sum(days.get(today - dt.timedelta(days=i), 0) for i in range(7)))
    last30 = int(sum(days.get(today - dt.timedelta(days=i), 0) for i in range(30)))
    longest, current = streaks(days)

    month_labels = {}
    for wi, week in enumerate(weeks):
        for day in week:
            if day.day == 1:
                month_labels[wi] = MONTHS[day.month - 1]

    cells = []
    for wi, week in enumerate(weeks):
        for di, day in enumerate(week):
            v = days.get(day, 0)
            lvl = level_for(v, b)
            cells.append(
                f'<rect class="d" data-level="{lvl}" x="{wi * step}" y="{di * step}" '
                f'width="{cell}" height="{cell}" rx="2">'
                f'<title>{day.isoformat()}: {fmt(v)} gen tokens</title></rect>'
            )

    labels = "".join(
        f'<text class="m" x="{wi * step + 2}" y="{cell - 2}">{month_labels[wi]}</text>'
        for wi in sorted(month_labels)
    )
    wk_labels = "".join(
        f'<text class="w" x="0" y="{di * step + cell}">{WEEKDAYS[di]}</text>'
        for di in range(7)
    )
    svg_h = 7 * step + 4

    today_s = today.strftime("%d %b %Y")
    started_s = oldest.strftime("%d %b %Y, %H:%M") if days else "—"
    stats_html = f"""
  <div class="stats">
    <div class="stat" title="Output tokens produced by the model since the ledger started recording">
      <div class="v">{fmt(total_gen)}</div><div class="k">gen tokens · lifetime</div></div>
    <div class="stat" title="Input tokens sent to the model (prompts + cached prefixes) since the ledger started">
      <div class="v">{fmt(total_prompt)}</div><div class="k">prompt tokens · lifetime</div></div>
    <div class="stat" title="Completed API requests since the ledger started">
      <div class="v">{fmt(total_req)}</div><div class="k">requests · lifetime</div></div>
    <div class="stat" title="Generated tokens in the last 7 days">
      <div class="v">{fmt(last7)}</div><div class="k">gen tokens / 7d</div></div>
    <div class="stat" title="Generated tokens in the last 30 days">
      <div class="v">{fmt(last30)}</div><div class="k">gen tokens / 30d</div></div>
    <div class="stat" title="Consecutive days (ending today) with at least one generated token">
      <div class="v">{current}</div><div class="k">day streak</div></div>
    <div class="stat" title="Longest run of consecutive days with at least one generated token">
      <div class="v">{longest}</div><div class="k">best streak</div></div>
  </div>"""

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Local inference token usage — desktop</title>
<style>
  body {{ font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
         background: #0d1117; color: #e6edf3; margin: 0; padding: 40px 24px; }}
  main {{ max-width: 940px; margin: 0 auto; }}
  h1 {{ font-size: 20px; margin: 0 0 4px; }}
  .sub {{ color: #8b949e; font-size: 13px; margin-bottom: 8px; }}
  .stats {{ display: flex; flex-wrap: wrap; gap: 8px; margin: 22px 0 30px; }}
  .stat {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
           padding: 12px 18px; min-width: 120px; cursor: help; }}
  .stat .v {{ font-size: 22px; font-weight: 600; }}
  .stat .k {{ color: #8b949e; font-size: 11px; text-transform: uppercase;
              letter-spacing: .05em; margin-top: 2px; }}
  svg {{ max-width: 100%; height: auto; }}
  .d {{ shape-rendering: geometricPrecision; stroke: none; }}
  .d[data-level="0"] {{ fill: #161b22; }}
  .d[data-level="1"] {{ fill: #0e4429; }}
  .d[data-level="2"] {{ fill: #006d32; }}
  .d[data-level="3"] {{ fill: #26a641; }}
  .d[data-level="4"] {{ fill: #39d353; }}
  .m {{ fill: #8b949e; font-size: 10px; }}
  .w {{ fill: #8b949e; font-size: 10px; }}
  .keys {{ display: flex; align-items: center; gap: 8px; margin-top: 8px;
           color: #8b949e; font-size: 11px; }}
  .bars {{ margin-top: 34px; }}
  .bars h2 {{ font-size: 14px; margin: 0 0 14px; }}
  .bar-row {{ display: flex; align-items: center; gap: 10px; margin-bottom: 6px; }}
  .bar-date {{ width: 110px; color: #8b949e; font-size: 12px; text-align: right; }}
  .bar-track {{ flex: 1; max-width: 420px; background: #21262d; border-radius: 4px;
                height: 14px; overflow: hidden; }}
  .bar-fill {{ height: 100%; background: #26a641; border-radius: 4px; }}
  .bar-val {{ width: 64px; font-size: 12px; text-align: right; }}
  .explain {{ margin-top: 34px; background: #161b22; border: 1px solid #30363d;
              border-radius: 8px; padding: 16px 20px; font-size: 13px;
              line-height: 1.55; color: #c9d1d9; }}
  .explain h2 {{ font-size: 14px; margin: 0 0 8px; }}
  .explain p {{ margin: 8px 0; }}
  .explain code {{ background: #21262d; padding: 1px 5px; border-radius: 4px; }}
</style>
</head>
<body>
<main>
  <h1>Local inference token usage <span style="color:#8b949e;font-weight:400">— desktop (all engines and models)</span></h1>
  <div class="sub">Durable ledger, written to /var/lib/vllm-stats/stats.csv every 15 min · ledger last recorded {last_recorded} · page refreshed {dt.datetime.now().strftime('%d %b %Y %H:%M')}</div>
  <div class="sub">Calendar: generated tokens per day (darker = more). Hover any square for the exact count.</div>

  {stats_html}

  <div class="keys">Around key: {legend(cell, step)}</div>

  <div class="bars">
    <h2>Last 14 days — generated tokens</h2>
    {bar_rows(days)}
  </div>

  <div class="explain">
    <h2>Reading the numbers</h2>
    <p><b>What this page is:</b> once a day's square is dark, some output tokens were generated that day. The calendar shows at most the last 12 months; all-time totals are in the cards (hover them for definitions). It's the same data Grafana shows, but with a different baseline:</p>
    <p><b>Why the totals differ from Grafana:</b> Grafana reads the active engine's live /metrics counters, which <i>reset whenever its container restarts or the runtime changes</i>. This ledger detects vLLM and SGLang, records every 15-minute delta to disk, and never resets. When it started (12 Aug 2026, ~20:45) it <b>backfilled the active container's counters as a single row</b>. After a restart or engine switch, Grafana's process totals start over while the ledger keeps counting — that's its job.</p>
    <p><b>Streak:</b> a day counts when at least one generation token was produced. Current streak ends today; if today is still empty it may not have started yet.</p>
    <p class="sub">Raw data: /var/lib/vllm-stats/stats.csv on desktop — one row per 15 minutes: <code>timestamp, local time, prompt tokens, generation tokens, requests</code>.</p>
  </div>
</main>
</body>
</html>
"""
    if out_path is not None:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        tmp = out_path + ".tmp"
        with open(tmp, "w") as f:
            f.write(page)
        os.replace(tmp, out_path)
    return dict(total_gen=total_gen, total_prompt=total_prompt, total_req=total_req,
                last7=last7, last30=last30, current=current, longest=longest,
                start=start.isoformat(), days=len(days))


def csv_rows():
    path = os.path.join(DIR, "stats.csv")
    if not os.path.exists(path):
        return []
    with open(path, newline="") as f:
        return [r for r in csv.reader(f) if r and r[0] != "ts"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--write", action="store_true",
                    help="write the HTML page (default: summary only)")
    args = ap.parse_args()

    days = load(os.path.join(DIR, "stats.csv"))
    if not days:
        print("no ledger data yet — first run only seeds the baseline")
        return 0

    out_path = DEFAULT_OUT if args.write else None
    s = render(days, out_path)
    print(f"gen tokens: {fmt(s['total_gen'])} lifetime | {fmt(s['last7'])} 7d | {fmt(s['last30'])} 30d")
    print(f"prompt tokens: {fmt(s['total_prompt'])} lifetime | requests: {fmt(s['total_req'])}")
    print(f"streak: {s['current']} days current, {s['longest']} best | since {s['start']}")
    if args.write:
        print(f"heatmap written to {out_path} (open in a browser)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
