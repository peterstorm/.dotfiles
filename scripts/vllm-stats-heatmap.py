#!/usr/bin/env python3
"""GitHub-style calendar heatmap of vLLM token usage.

Reads the ledger written by vllm-stats-record.py (per-interval token deltas)
and renders a self-contained static HTML page: generation tokens per day as a
GitHub-style contribution calendar, with headline lifetime stats.

Output (--write):  <VLLM_STATS_DIR>/heatmap/index.html
Summary:           printed to stdout either way.
"""
import argparse
import csv
import datetime as dt
import html
import os
import sys

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_OUT = os.path.join(DIR, "heatmap", "index.html")

# GitHub's palette
LEVELS = ["#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39"]
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
    # longest run
    longest = cur = 1
    prev = sorted(active)[0]
    for d in sorted(active)[1:]:
        cur = cur + 1 if (d - prev).days == 1 else 1
        longest = max(longest, cur)
        prev = d
    # current run ending at the most recent active day
    cur = 0
    d = max(active)
    while d in active:
        cur += 1
        d -= dt.timedelta(days=1)
    return longest, cur


def render(days, out_path):
    today = dt.date.today()
    oldest = min(days) if days else today
    start = max(oldest, today - dt.timedelta(days=364))  # a year of history
    # Align the grid: first column starts on a Sunday
    start -= dt.timedelta(days=start.weekday() + 1)  # back up to Sunday
    weeks = []
    d = start
    while d <= today:
        weeks.append([d + dt.timedelta(days=i) for i in range(7)])
        d += dt.timedelta(days=7)

    nonzero = [v for v in days.values() if v > 0]
    b = buckets(nonzero)

    total_gen = int(sum(days.values()))
    total_prompt = int(sum(float(r[2] or 0) for r in csv_rows()))
    total_req = int(sum(float(r[4] or 0) for r in csv_rows()))
    last7 = int(sum(days.get(today - dt.timedelta(days=i), 0) for i in range(7)))
    last30 = int(sum(days.get(today - dt.timedelta(days=i), 0) for i in range(30)))
    longest, current = streaks(days)

    # month labels above the column that contains the 1st of a month
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
            title = f"{day.isoformat()}: {fmt(v)} gen tokens"
            cells.append(
                f'<rect class="d" data-level="{lvl}" x="{wi * 13}" y="{di * 13}" '
                f'width="11" height="11" rx="2"><title>{title}</title></rect>'
            )

    labels = "".join(
        f'<text class="m" x="{wi * 13 + 2}" y="0">{month_labels[wi]}</text>'
        for wi in sorted(month_labels)
    )
    wk_labels = "".join(
        f'<text class="w" x="0" y="{di * 13 + 10}">{WEEKDAYS[di]}</text>'
        for di in range(7)
    )

    legend = "".join(
        f'<rect class="d" data-level="{i}" x="{i * 13}" y="0" width="11" height="11" rx="2"></rect>'
        for i in range(5)
    )

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vLLM token usage — desktop</title>
<style>
  body {{ font-family: -apple-system, "Segoe UI", Helvetica, Arial, sans-serif;
         background: #0d1117; color: #e6edf3; margin: 0; padding: 40px 24px; }}
  main {{ max-width: 940px; margin: 0 auto; }}
  h1 {{ font-size: 20px; margin: 0 0 4px; }}
  .sub {{ color: #8b949e; font-size: 13px; margin-bottom: 28px; }}
  .stats {{ display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 32px; }}
  .stat {{ background: #161b22; border: 1px solid #30363d; border-radius: 8px;
           padding: 12px 18px; min-width: 120px; }}
  .stat .v {{ font-size: 22px; font-weight: 600; }}
  .stat .k {{ color: #8b949e; font-size: 11px; text-transform: uppercase;
              letter-spacing: .05em; margin-top: 2px; }}
  svg {{ max-width: 100%; }}
  .d {{ shape-rendering: geometricPrecision; }}
  .m {{ fill: #8b949e; font-size: 10px; }}
  .w {{ fill: #8b949e; font-size: 10px; }}
  .keys {{ display: flex; align-items: center; gap: 6px; margin-top: 8px;
           color: #8b949e; font-size: 11px; }}
</style>
</head>
<body>
<main>
  <h1>vLLM token usage <span style="color:#8b949e;font-weight:400">— desktop (deepseek-v4-flash)</span></h1>
  <div class="sub">Append-only ledger since {oldest.isoformat()} · {len(cells)} days tracked · generated {dt.datetime.now().strftime('%Y-%m-%d %H:%M')}</div>

  <div class="stats">
    <div class="stat"><div class="v">{fmt(total_gen)}</div><div class="k">gen tokens (lifetime)</div></div>
    <div class="stat"><div class="v">{fmt(total_prompt)}</div><div class="k">prompt tokens (lifetime)</div></div>
    <div class="stat"><div class="v">{fmt(total_req)}</div><div class="k">requests (lifetime)</div></div>
    <div class="stat"><div class="v">{fmt(last7)}</div><div class="k">gen tokens / 7d</div></div>
    <div class="stat"><div class="v">{fmt(last30)}</div><div class="k">gen tokens / 30d</div></div>
    <div class="stat"><div class="v">{current}</div><div class="k">day streak</div></div>
    <div class="stat"><div class="v">{longest}</div><div class="k">best streak</div></div>
  </div>

  <svg viewBox="0 0 {len(weeks) * 13 + 40} 110" xmlns="http://www.w3.org/2000/svg">
    {labels}
    {wk_labels}
    {''.join(cells)}
  </svg>
  <div class="keys">
    <span>Less</span>{legend}<span>More</span>
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
        print("no ledger data yet — is vllm-stats-record running?")
        return 1

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
