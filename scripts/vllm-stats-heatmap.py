#!/usr/bin/env python3
"""Render the model-aware durable inference ledger as self-contained HTML."""
import argparse
import csv
import datetime as dt
import html
import os
import sys
from collections import defaultdict

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_OUT = os.path.join(DIR, "heatmap", "index.html")
LEGACY_MODEL = "Historical aggregate"
ALL_MODELS = "All models"
LEGACY_COLUMNS = ["ts", "when", "prompt_tokens", "generation_tokens", "requests"]

WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def number(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def optional_number(value):
    try:
        return float(value) if value not in (None, "") else None
    except (TypeError, ValueError):
        return None


def fmt(value):
    value = int(value)
    if value >= 1_000_000_000:
        return f"{value / 1e9:.2f}B"
    if value >= 1_000_000:
        return f"{value / 1e6:.1f}M"
    if value >= 1_000:
        return f"{value / 1e3:.0f}K"
    return str(value)


def fmt_rate(value):
    if value is None:
        return "—"
    if value >= 1_000:
        return f"{value / 1_000:.1f}K"
    if value >= 100:
        return f"{value:.0f}"
    if value >= 10:
        return f"{value:.1f}"
    return f"{value:.2f}"


def parse_row(row):
    try:
        timestamp = int(row.get("ts", ""))
    except (TypeError, ValueError):
        return None
    return {
        "ts": timestamp,
        "when": row.get("when", ""),
        "model": row.get("model") or LEGACY_MODEL,
        "engine": row.get("engine") or "legacy",
        "endpoint": row.get("endpoint") or "legacy",
        "prompt": number(row.get("prompt_tokens")),
        "generation": number(row.get("generation_tokens")),
        "requests": number(row.get("requests")),
        "interval": optional_number(row.get("interval_seconds")),
        "prompt_rate": optional_number(row.get("prompt_tokens_per_second")),
        "generation_rate": optional_number(row.get("generation_tokens_per_second")),
    }


def load(path):
    if not os.path.exists(path):
        return []
    with open(path, newline="") as stream:
        reader = csv.reader(stream)
        raw_rows = list(reader)
    if not raw_rows:
        return []
    header = raw_rows[0]
    if header == LEGACY_COLUMNS:
        rows = [
            {
                "ts": row[0], "when": row[1], "model": LEGACY_MODEL,
                "engine": "legacy", "endpoint": "legacy",
                "prompt_tokens": row[2], "generation_tokens": row[3], "requests": row[4],
                "interval_seconds": "", "prompt_tokens_per_second": "",
                "generation_tokens_per_second": "",
            }
            for row in raw_rows[1:] if len(row) == 5
        ]
    else:
        rows = [dict(zip(header, row)) for row in raw_rows[1:] if row]
    return [parsed for row in rows if (parsed := parse_row(row)) is not None]


def model_names(rows):
    names = sorted({row["model"] for row in rows if row["model"] != LEGACY_MODEL}, key=str.casefold)
    if any(row["model"] == LEGACY_MODEL for row in rows):
        names.append(LEGACY_MODEL)
    return names


def select_rows(rows, model):
    return rows if model == ALL_MODELS else [row for row in rows if row["model"] == model]


def daily_generation(rows):
    days = defaultdict(float)
    for row in rows:
        days[dt.date.fromtimestamp(row["ts"])] += row["generation"]
    return dict(days)


def buckets(nonzero):
    """Quantile-style bins like GitHub: four equal-count nonzero groups."""
    if not nonzero:
        return [0, 0, 0, 0]
    values = sorted(nonzero)
    size = len(values)
    return [values[size * (index + 1) // 4 - 1] for index in range(4)]


def level_for(value, boundaries):
    if value <= 0:
        return 0
    for level, boundary in enumerate(boundaries, 1):
        if value <= boundary:
            return level
    return 4


def streaks(days):
    active = {day for day, value in days.items() if value > 0}
    if not active:
        return 0, 0
    ordered = sorted(active)
    longest = current_run = 1
    for previous, day in zip(ordered, ordered[1:]):
        current_run = current_run + 1 if (day - previous).days == 1 else 1
        longest = max(longest, current_run)
    current = 0
    day = max(active)
    while day in active:
        current += 1
        day -= dt.timedelta(days=1)
    return longest, current


def aggregate(rows, today=None):
    today = today or dt.date.today()
    days = daily_generation(rows)
    latest_ts = max((row["ts"] for row in rows), default=None)
    latest_rows = [row for row in rows if row["ts"] == latest_ts]
    longest, current = streaks(days)
    return {
        "days": days,
        "total_generation": sum(row["generation"] for row in rows),
        "total_prompt": sum(row["prompt"] for row in rows),
        "total_requests": sum(row["requests"] for row in rows),
        "last7": sum(days.get(today - dt.timedelta(days=index), 0) for index in range(7)),
        "last30": sum(days.get(today - dt.timedelta(days=index), 0) for index in range(30)),
        "longest": longest,
        "current": current,
        "latest_prompt_rate": sum(row["prompt_rate"] or 0 for row in latest_rows)
        if any(row["prompt_rate"] is not None for row in latest_rows) else None,
        "latest_generation_rate": sum(row["generation_rate"] or 0 for row in latest_rows)
        if any(row["generation_rate"] is not None for row in latest_rows) else None,
        "latest_ts": latest_ts,
    }


def legend(cell, step):
    squares = "".join(
        f'<rect class="day" data-level="{level}" x="{level * step}" y="0" '
        f'width="{cell}" height="{cell}" rx="2"></rect>'
        for level in range(5)
    )
    return (
        f'<span>Less</span><svg aria-hidden="true" width="{5 * step}" height="{cell}">'
        f'{squares}</svg><span>More</span>'
    )


def calendar(days, today):
    oldest = min(days) if days else today
    start = max(oldest, today - dt.timedelta(days=364))
    # Keep a short new ledger visually legible: twelve weeks establish the
    # calendar rhythm without pretending older activity exists.
    start = min(start, today - dt.timedelta(days=84))
    start -= dt.timedelta(days=start.weekday() + 1)
    weeks = []
    day = start
    while day <= today:
        weeks.append([day + dt.timedelta(days=index) for index in range(7)])
        day += dt.timedelta(days=7)

    cell = 11 if len(weeks) >= 26 else 16
    gap = 2 if cell == 11 else 4
    step = cell + gap
    width = max(280, len(weeks) * step + 42)
    boundaries = buckets([value for value in days.values() if value > 0])
    month_labels = {}
    for week_index, week in enumerate(weeks):
        for date in week:
            if date.day == 1:
                month_labels[week_index] = MONTHS[date.month - 1]

    cells = []
    for week_index, week in enumerate(weeks):
        for day_index, date in enumerate(week):
            value = days.get(date, 0)
            cells.append(
                f'<rect class="day" data-level="{level_for(value, boundaries)}" '
                f'x="{week_index * step + 40}" y="{day_index * step + 18}" '
                f'width="{cell}" height="{cell}" rx="2">'
                f'<title>{date.isoformat()}: {fmt(value)} generated tokens</title></rect>'
            )
    labels = "".join(
        f'<text class="axis-label" x="{week_index * step + 42}" y="11">{month_labels[week_index]}</text>'
        for week_index in sorted(month_labels)
    )
    weekdays = "".join(
        f'<text class="axis-label" x="0" y="{day_index * step + cell + 18}">{WEEKDAYS[day_index]}</text>'
        for day_index in (1, 3, 5)
    )
    height = 7 * step + 24
    return (
        '<div class="calendar-scroll">'
        f'<svg class="calendar" role="img" aria-label="Generated tokens by day" '
        f'viewBox="0 0 {width} {height}">{labels}{weekdays}{"".join(cells)}</svg>'
        '</div>'
        f'<div class="legend">{legend(cell, step)}</div>'
    )


def bar_rows(days):
    recent = sorted(days.items(), reverse=True)[:14]
    recent.reverse()
    if not recent:
        return '<p class="empty">No generated tokens in this selection yet.</p>'
    maximum = max(value for _, value in recent) or 1
    rows = []
    for date, value in recent:
        width = 0 if value == 0 else max(2, value / maximum * 100)
        rows.append(
            '<div class="bar-row">'
            f'<span class="bar-date">{date.strftime("%a %d %b")}</span>'
            f'<div class="bar-track"><div class="bar-fill" style="width:{width:.1f}%"></div></div>'
            f'<span class="bar-value">{fmt(value)}</span></div>'
        )
    return "".join(rows)


def throughput_points(rows, end_ts):
    cutoff = end_ts - 24 * 60 * 60
    by_timestamp = {}
    for row in rows:
        if row["ts"] < cutoff or row["prompt_rate"] is None or row["generation_rate"] is None:
            continue
        point = by_timestamp.setdefault(row["ts"], [0.0, 0.0])
        point[0] += row["prompt_rate"]
        point[1] += row["generation_rate"]
    return [(timestamp, *rates) for timestamp, rates in sorted(by_timestamp.items())]


def throughput_chart(rows, end_ts, chart_id):
    points = throughput_points(rows, end_ts)
    if not points:
        return (
            '<div class="empty chart-empty"><strong>No comparable rate history yet.</strong>'
            '<span>Served-throughput tracking begins with the model-aware ledger.</span></div>'
        )
    width, height = 760, 250
    left, right, top, bottom = 54, 16, 18, 38
    plot_width, plot_height = width - left - right, height - top - bottom
    start_ts = end_ts - 24 * 60 * 60
    maximum = max(max(prompt, generation) for _, prompt, generation in points) or 1

    def x(timestamp):
        return left + (timestamp - start_ts) / (24 * 60 * 60) * plot_width

    def y(value):
        return top + plot_height - value / maximum * plot_height

    def polyline(index, css_class):
        coordinates = " ".join(f"{x(point[0]):.1f},{y(point[index]):.1f}" for point in points)
        circles = "".join(
            f'<circle class="point {css_class}" cx="{x(point[0]):.1f}" cy="{y(point[index]):.1f}" r="2.5">'
            f'<title>{dt.datetime.fromtimestamp(point[0]).strftime("%d %b %H:%M")}: '
            f'{fmt_rate(point[index])} tokens/s</title></circle>'
            for point in points
        )
        return f'<polyline class="line {css_class}" points="{coordinates}"></polyline>{circles}'

    grid = "".join(
        f'<g><line class="grid-line" x1="{left}" x2="{width-right}" y1="{top + plot_height * index / 4:.1f}" y2="{top + plot_height * index / 4:.1f}"></line>'
        f'<text class="axis-label" x="{left-8}" y="{top + plot_height * index / 4 + 3:.1f}" text-anchor="end">{fmt_rate(maximum * (4-index) / 4)}</text></g>'
        for index in range(5)
    )
    labels = "".join(
        f'<text class="axis-label" x="{left + plot_width * fraction:.1f}" y="{height-10}" text-anchor="middle">'
        f'{dt.datetime.fromtimestamp(start_ts + 24 * 60 * 60 * fraction).strftime("%H:%M")}</text>'
        for fraction in (0, 0.5, 1)
    )
    title_id = f"{chart_id}-title"
    return (
        f'<svg class="throughput" role="img" aria-labelledby="{title_id}" viewBox="0 0 {width} {height}">'
        f'<title id="{title_id}">Prompt and generation served throughput over the last 24 hours</title>'
        f'{grid}{labels}{polyline(1, "prompt-line")}{polyline(2, "generation-line")}</svg>'
        '<div class="chart-key"><span class="prompt-key">Prompt</span><span class="generation-key">Generation</span>'
        '<span class="chart-unit">tokens/s · interval average</span></div>'
    )


def metric_strip(summary):
    metrics = [
        (fmt(summary["total_generation"]), "Generated · lifetime", "Output tokens recorded for this selection"),
        (fmt(summary["total_prompt"]), "Prompt · lifetime", "Submitted input tokens recorded for this selection"),
        (fmt(summary["total_requests"]), "Requests · lifetime", "Completed generation requests"),
        (fmt(summary["last7"]), "Generated · 7 days", "Output tokens over the latest seven calendar days"),
        (fmt(summary["last30"]), "Generated · 30 days", "Output tokens over the latest thirty calendar days"),
        (str(summary["current"]), "Current streak", "Consecutive active days ending at the latest active day"),
    ]
    return '<div class="metric-strip">' + "".join(
        f'<div class="metric" title="{html.escape(title)}"><strong>{value}</strong><span>{label}</span></div>'
        for value, label, title in metrics
    ) + '</div>'


def comparison_table(rows, models):
    body = []
    for index, model in enumerate(models, 1):
        selected = select_rows(rows, model)
        summary = aggregate(selected)
        engines = ", ".join(sorted({row["engine"] for row in selected}))
        body.append(
            '<tr>'
            f'<th scope="row"><button class="table-select" data-select="panel-{index}">{html.escape(model)}</button>'
            f'<span>{html.escape(engines)}</span></th>'
            f'<td>{fmt(summary["total_generation"])}</td><td>{fmt(summary["total_prompt"])}</td>'
            f'<td>{fmt(summary["total_requests"])}</td>'
            f'<td>{fmt_rate(summary["latest_generation_rate"])}</td>'
            f'<td>{fmt_rate(summary["latest_prompt_rate"])}</td>'
            '</tr>'
        )
    return (
        '<div class="table-wrap"><table><thead><tr><th>Model</th><th>Generated</th><th>Prompt</th>'
        '<th>Requests</th><th>Latest gen/s</th><th>Latest prompt/s</th></tr></thead>'
        f'<tbody>{"".join(body)}</tbody></table></div>'
    )


def model_panel(rows, model, panel_id, hidden, today, end_ts):
    selected = select_rows(rows, model)
    summary = aggregate(selected, today)
    description = (
        "Combined durable history across every recorded model."
        if model == ALL_MODELS
        else "Legacy totals recorded before model identity was added; they cannot be safely attributed."
        if model == LEGACY_MODEL
        else f"Durable usage attributed to {model}."
    )
    return f'''
<section class="model-panel" id="{panel_id}" data-model="{html.escape(model)}"{' hidden' if hidden else ''}>
  <div class="panel-heading"><div><h2>{html.escape(model)}</h2><p>{html.escape(description)}</p></div>
    <div class="live-rates" title="Most recent complete ledger interval, including idle time">
      <span><strong>{fmt_rate(summary['latest_generation_rate'])}</strong> gen/s</span>
      <span><strong>{fmt_rate(summary['latest_prompt_rate'])}</strong> prompt/s</span>
    </div></div>
  {metric_strip(summary)}
  <div class="data-grid">
    <article><h3>Generated-token activity</h3><p class="section-note">Daily output over the last twelve months.</p>
      {calendar(summary['days'], today)}</article>
    <article><h3>Served throughput · 24 hours</h3><p class="section-note">Wall-clock interval averages, including idle time.</p>
      {throughput_chart(selected, end_ts, panel_id)}</article>
  </div>
  <article class="bars"><h3>Last 14 active days</h3>{bar_rows(summary['days'])}</article>
</section>'''


def render(rows, out_path):
    if not rows:
        raise ValueError("cannot render an empty ledger")
    today = dt.date.today()
    end_ts = max(row["ts"] for row in rows)
    models = model_names(rows)
    choices = [ALL_MODELS, *models]
    latest_row = max(rows, key=lambda row: row["ts"])
    last_recorded = latest_row["when"] or dt.datetime.fromtimestamp(end_ts).strftime("%Y-%m-%d %H:%M:%S")

    selector = "".join(
        f'<button class="model-button" type="button" data-panel="panel-{index}" '
        f'aria-controls="panel-{index}" aria-pressed="{"true" if index == 0 else "false"}">'
        f'{html.escape(model)}</button>'
        for index, model in enumerate(choices)
    )
    panels = "".join(
        model_panel(rows, model, f"panel-{index}", index != 0, today, end_ts)
        for index, model in enumerate(choices)
    )
    all_summary = aggregate(rows, today)
    started = dt.date.fromtimestamp(min(row["ts"] for row in rows)).strftime("%d %b %Y")

    page = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Local inference usage — desktop</title>
<style>
  :root {{ --bg:#0d1117; --surface:#161b22; --surface-2:#1c2128; --border:#30363d;
    --text:#e6edf3; --muted:#9aa4af; --green:#3fb950; --green-soft:#238636;
    --cyan:#58a6ff; --orange:#f0883e; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; padding:36px 24px 56px; background:var(--bg); color:var(--text);
    font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; }}
  main {{ max-width:1120px; margin:0 auto; }}
  h1,h2,h3,p {{ margin-top:0; }}
  h1 {{ margin-bottom:6px; font-size:22px; letter-spacing:-.02em; }}
  h2 {{ margin-bottom:3px; font-size:18px; }}
  h3 {{ margin-bottom:2px; font-size:14px; }}
  .meta,.section-note,.panel-heading p {{ color:var(--muted); }}
  .meta {{ max-width:75ch; margin-bottom:22px; font-size:13px; }}
  .model-nav {{ display:flex; gap:6px; overflow-x:auto; padding:3px 0 14px; margin-bottom:18px; }}
  button {{ font:inherit; }}
  .model-button {{ flex:none; border:1px solid var(--border); border-radius:6px; color:var(--muted);
    background:transparent; padding:7px 11px; cursor:pointer; transition:background-color 160ms,color 160ms,border-color 160ms; }}
  .model-button:hover {{ color:var(--text); border-color:#59636e; }}
  .model-button[aria-pressed="true"] {{ color:#fff; background:var(--green-soft); border-color:var(--green-soft); }}
  button:focus-visible {{ outline:2px solid var(--cyan); outline-offset:2px; }}
  .panel-heading {{ display:flex; justify-content:space-between; align-items:end; gap:24px; margin-bottom:18px; }}
  .panel-heading p {{ margin:0; max-width:65ch; font-size:13px; }}
  .live-rates {{ display:flex; gap:18px; flex:none; color:var(--muted); font-size:12px; }}
  .live-rates strong {{ color:var(--text); font-size:16px; margin-right:4px; }}
  .metric-strip {{ display:grid; grid-template-columns:repeat(6,minmax(0,1fr)); border-block:1px solid var(--border);
    margin-bottom:28px; }}
  .metric {{ min-width:0; padding:14px 14px 13px 0; }}
  .metric + .metric {{ border-left:1px solid var(--border); padding-left:14px; }}
  .metric strong,.metric span {{ display:block; }}
  .metric strong {{ font-size:20px; line-height:1.2; font-variant-numeric:tabular-nums; }}
  .metric span {{ margin-top:4px; color:var(--muted); font-size:10px; text-transform:uppercase; letter-spacing:.055em; }}
  .data-grid {{ display:grid; grid-template-columns:minmax(0,1.35fr) minmax(320px,1fr); gap:16px; align-items:start; }}
  article {{ min-width:0; background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:18px; }}
  .section-note {{ margin-bottom:16px; font-size:12px; }}
  .calendar-scroll {{ overflow-x:auto; padding-bottom:4px; }}
  .calendar {{ min-width:100%; height:auto; display:block; }}
  .day {{ shape-rendering:geometricPrecision; }}
  .day[data-level="0"] {{ fill:#21262d; }} .day[data-level="1"] {{ fill:#0e4429; }}
  .day[data-level="2"] {{ fill:#006d32; }} .day[data-level="3"] {{ fill:#26a641; }}
  .day[data-level="4"] {{ fill:#39d353; }}
  .axis-label {{ fill:var(--muted); font-size:10px; }}
  .legend,.chart-key {{ display:flex; align-items:center; gap:7px; color:var(--muted); font-size:11px; }}
  .legend {{ justify-content:flex-end; margin-top:7px; }}
  .throughput {{ display:block; width:100%; min-height:220px; }}
  .grid-line {{ stroke:var(--border); stroke-width:1; }}
  .line {{ fill:none; stroke-width:2; stroke-linecap:round; stroke-linejoin:round; }}
  .point {{ stroke:none; }} .prompt-line {{ stroke:var(--cyan); fill:var(--cyan); }}
  .generation-line {{ stroke:var(--orange); fill:var(--orange); }}
  .chart-key span::before {{ content:""; display:inline-block; width:14px; height:2px; margin:0 6px 3px 0; }}
  .chart-key .prompt-key::before {{ background:var(--cyan); }} .chart-key .generation-key::before {{ background:var(--orange); }}
  .chart-key .chart-unit {{ margin-left:auto; }} .chart-key .chart-unit::before {{ display:none; }}
  .empty {{ color:var(--muted); }} .chart-empty {{ min-height:220px; display:flex; flex-direction:column; justify-content:center; align-items:center; text-align:center; gap:4px; }}
  .chart-empty strong {{ color:var(--text); font-size:14px; }}
  .bars {{ margin-top:16px; }} .bars h3 {{ margin-bottom:14px; }}
  .bar-row {{ display:grid; grid-template-columns:100px minmax(80px,420px) 64px; align-items:center; gap:10px; margin:6px 0; }}
  .bar-date {{ color:var(--muted); font-size:12px; text-align:right; }}
  .bar-track {{ height:12px; overflow:hidden; background:#21262d; border-radius:3px; }}
  .bar-fill {{ height:100%; background:var(--green); border-radius:3px; }}
  .bar-value {{ font-size:12px; text-align:right; font-variant-numeric:tabular-nums; }}
  .comparison {{ margin-top:30px; }} .comparison h2 {{ margin-bottom:4px; }}
  .comparison > p {{ color:var(--muted); margin-bottom:12px; font-size:13px; }}
  .table-wrap {{ overflow-x:auto; border:1px solid var(--border); border-radius:8px; }}
  table {{ width:100%; border-collapse:collapse; min-width:720px; background:var(--surface); font-variant-numeric:tabular-nums; }}
  th,td {{ padding:11px 14px; border-bottom:1px solid var(--border); text-align:right; }}
  thead th {{ color:var(--muted); background:var(--surface-2); font-size:11px; font-weight:600; }}
  th:first-child {{ text-align:left; }} tbody tr:last-child th,tbody tr:last-child td {{ border-bottom:0; }}
  tbody th span {{ display:block; color:var(--muted); font-size:11px; font-weight:400; }}
  .table-select {{ border:0; padding:0; color:var(--text); background:none; cursor:pointer; font-weight:600; }}
  .table-select:hover {{ color:var(--cyan); text-decoration:underline; }}
  .explain {{ margin-top:30px; border-top:1px solid var(--border); padding-top:22px; max-width:76ch; color:#c9d1d9; }}
  .explain h2 {{ font-size:15px; }} .explain p {{ margin:8px 0; }}
  code {{ background:#21262d; border-radius:4px; padding:1px 5px; }}
  [hidden] {{ display:none !important; }}
  @media (max-width:860px) {{
    .metric-strip {{ grid-template-columns:repeat(3,1fr); }}
    .metric:nth-child(4) {{ border-left:0; padding-left:0; }}
    .metric:nth-child(n+4) {{ border-top:1px solid var(--border); }}
    .data-grid {{ grid-template-columns:1fr; }}
  }}
  @media (max-width:560px) {{
    body {{ padding:24px 16px 40px; }}
    .panel-heading {{ align-items:start; flex-direction:column; gap:10px; }}
    .metric-strip {{ grid-template-columns:repeat(2,1fr); }}
    .metric:nth-child(3),.metric:nth-child(5) {{ border-left:0; padding-left:0; }}
    .metric:nth-child(n+3) {{ border-top:1px solid var(--border); }}
    .metric:nth-child(4) {{ border-left:1px solid var(--border); padding-left:14px; }}
    article {{ padding:14px; }}
    .bar-row {{ grid-template-columns:80px minmax(60px,1fr) 52px; gap:7px; }}
    .bar-date {{ font-size:11px; }}
  }}
  @media (prefers-reduced-motion:reduce) {{ * {{ scroll-behavior:auto !important; transition:none !important; }} }}
</style>
</head>
<body>
<main>
  <header>
    <h1>Local inference usage</h1>
    <p class="meta">Durable desktop ledger · last recorded {html.escape(last_recorded)} · refreshed {dt.datetime.now().strftime('%d %b %Y %H:%M')}</p>
    <nav class="model-nav" aria-label="Filter statistics by model">{selector}</nav>
  </header>
  {panels}
  <section class="comparison">
    <h2>Model comparison</h2>
    <p>Lifetime totals and rates from each model's latest complete observation interval.</p>
    {comparison_table(rows, models)}
  </section>
  <section class="explain">
    <h2>How to read this page</h2>
    <p><strong>Durable totals:</strong> engine counters reset whenever a container restarts or the runtime changes. This ledger records counter deltas to disk and continues across vLLM, SGLang, restarts, and engine switches.</p>
    <p><strong>Model history:</strong> rows recorded before model-aware tracking remain under <em>{LEGACY_MODEL}</em>. They are included in All models, but never falsely assigned to a current model.</p>
    <p><strong>Served throughput:</strong> prompt and generation token deltas divided by the actual wall time between observations. It includes idle time and describes delivered traffic, not raw prefill-kernel or decode-only speed.</p>
    <p>Tracking began {started}. Raw data lives at <code>/var/lib/vllm-stats/stats.csv</code> on desktop.</p>
  </section>
</main>
<script>
(() => {{
  const buttons = [...document.querySelectorAll('.model-button')];
  const panels = [...document.querySelectorAll('.model-panel')];
  function select(panelId, focus = false) {{
    buttons.forEach(button => {{
      const active = button.dataset.panel === panelId;
      button.setAttribute('aria-pressed', String(active));
      if (active && focus) button.focus();
    }});
    panels.forEach(panel => panel.hidden = panel.id !== panelId);
  }}
  buttons.forEach(button => button.addEventListener('click', () => select(button.dataset.panel)));
  document.querySelectorAll('[data-select]').forEach(button => button.addEventListener('click', () => {{
    select(button.dataset.select, true);
    window.scrollTo({{ top: 0, behavior: 'smooth' }});
  }}));
  document.querySelector('.model-nav').addEventListener('keydown', event => {{
    if (!['ArrowLeft','ArrowRight'].includes(event.key)) return;
    event.preventDefault();
    const current = buttons.findIndex(button => button.getAttribute('aria-pressed') === 'true');
    const direction = event.key === 'ArrowRight' ? 1 : -1;
    const next = (current + direction + buttons.length) % buttons.length;
    select(buttons[next].dataset.panel, true);
  }});
}})();
</script>
</body>
</html>
'''
    if out_path is not None:
        os.makedirs(os.path.dirname(out_path), exist_ok=True)
        temporary = f"{out_path}.{os.getpid()}.tmp"
        try:
            with open(temporary, "w") as stream:
                stream.write(page)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, out_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    return {
        "total_gen": int(all_summary["total_generation"]),
        "total_prompt": int(all_summary["total_prompt"]),
        "total_req": int(all_summary["total_requests"]),
        "last7": int(all_summary["last7"]),
        "last30": int(all_summary["last30"]),
        "models": models,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="write the HTML page")
    args = parser.parse_args()
    rows = load(os.path.join(DIR, "stats.csv"))
    if not rows:
        print("no ledger data yet — first run only seeds the baseline")
        return 0
    output = DEFAULT_OUT if args.write else None
    summary = render(rows, output)
    print(
        f"gen tokens: {fmt(summary['total_gen'])} lifetime | {fmt(summary['last7'])} 7d | "
        f"{fmt(summary['last30'])} 30d"
    )
    print(f"prompt tokens: {fmt(summary['total_prompt'])} lifetime | requests: {fmt(summary['total_req'])}")
    print(f"models: {', '.join(summary['models'])}")
    if args.write:
        print(f"stats page written to {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
