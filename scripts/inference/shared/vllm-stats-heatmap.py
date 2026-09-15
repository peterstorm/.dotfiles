#!/usr/bin/env python3
"""Render the model-aware durable inference ledger as self-contained HTML."""
import argparse
import csv
import datetime as dt
import html
import json
import os
import statistics
import sys
from collections import defaultdict

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_OUT = os.path.join(DIR, "heatmap", "index.html")
LEGACY_MODEL = "Historical aggregate"
ALL_MODELS = "All models"
LEGACY_COLUMNS = ["ts", "when", "prompt_tokens", "generation_tokens", "requests"]

WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# --- Cloud cost counterfactual -------------------------------------------
# Reference hosted prices per token, for pricing the recorded (self-hosted,
# $0 API-fee) usage as if it had been served by a hosted API.
PRICING_SOURCE = "LiteLLM model DB"
PRICING_AS_OF = "15 Sep 2026"
DEFAULT_CACHE_HIT = 0.80

# Measured serving draw (2026-09-15): 2× ~400 W GPUs at 96–97% util — vLLM
# busy-polls keep them near this between requests — plus ~150 W CPU/rest.
POWER_DRAW_WATTS = 950
DEFAULT_TARIFF = 0.30
# Intervals longer than this span downtime inside the observation gap; they
# deflate the rate and are excluded from the active-hour computation.
ACTIVE_WINDOW_MAX_SECS = 1200

PRICING = [
    {
        "id": "gpt-5.6-sol",
        "label": "GPT-5.6 Sol · OpenAI",
        "input": 4.0e-6, "output": 2.0e-5, "cache_read": 4.0e-7,
        "note": "$4.00/M in · $20.00/M out · $0.40/M cache-read",
    },
    {
        "id": "gpt-5.6-terra",
        "label": "GPT-5.6 Terra · OpenAI",
        "input": 2.0e-6, "output": 1.2e-5, "cache_read": 2.0e-7,
        "note": "$2.00/M in · $12.00/M out · $0.20/M cache-read",
    },
    {
        "id": "gpt-5.6-luna",
        "label": "GPT-5.6 Luna · OpenAI",
        "input": 2.0e-7, "output": 1.2e-6, "cache_read": 2.0e-8,
        "note": "$0.20/M in · $1.20/M out · $0.02/M cache-read",
    },
    {
        "id": "deepseek-v4.1-flash-openrouter",
        "label": "DeepSeek V4.1 Flash · OpenRouter",
        "input": 1.5e-7, "output": 6.0e-7, "cache_read": 3.0e-9,
        "note": "$0.15/M in · $0.60/M out · $0.003/M cache-read",
    },
    {
        "id": "deepseek-v4.1-flash-official",
        "label": "DeepSeek V4.1 Flash · official-pattern",
        "input": 3.0e-7, "output": 1.2e-6, "cache_read": 6.0e-9,
        "note": "$0.30/M in · $1.20/M out · mirrors DeepSeek's official v4-flash price",
    },
]

COST_CSS = """\
  .cost { margin-top:30px; } .cost h2 { margin-bottom:4px; }
  .cost > p { color:var(--muted); margin-bottom:14px; font-size:13px; max-width:76ch; }
  .cost-controls { display:flex; flex-wrap:wrap; gap:14px 22px; align-items:center;
    margin-bottom:14px; color:var(--muted); font-size:12px; }
  .cost-controls label { display:flex; align-items:center; gap:8px; }
  select { background:var(--surface-2); color:var(--text); border:1px solid var(--border);
    border-radius:6px; padding:6px 9px; font:inherit; }
  select:hover { border-color:#59636e; }
  input[type="range"] { accent-color:var(--green-soft); width:150px; }
  output { color:var(--text); font-variant-numeric:tabular-nums; min-width:36px; }
  .pricing-note { color:var(--muted); font-size:12px; }
  tfoot tr { border-top:1px solid var(--border); background:var(--surface-2); }
  tfoot th, tfoot td { border-bottom:0; }
  tfoot th { color:var(--text); font-weight:600; }
"""

RATE_CSS = """\
  .rate-grid { display:grid; grid-template-columns:repeat(4,minmax(0,1fr)); gap:12px; margin-bottom:14px; }
  .rate-card { min-width:0; background:var(--surface); border:1px solid var(--border);
    border-radius:8px; padding:14px; }
  .rate-card strong { display:block; font-size:18px; line-height:1.2; font-variant-numeric:tabular-nums; }
  .rate-card span { display:block; margin-top:4px; color:var(--muted); font-size:10px;
    text-transform:uppercase; letter-spacing:.055em; }
  .rate-card .sub { text-transform:none; letter-spacing:0; font-size:11px; color:var(--muted); }
  .rate-card .sub span { display:inline; margin-top:0; font-size:11px; text-transform:none;
    letter-spacing:0; font-variant-numeric:tabular-nums; }
  input[type="number"] { background:var(--surface-2); color:var(--text); border:1px solid var(--border);
    border-radius:6px; padding:6px 9px; font:inherit; width:90px; }
  @media (max-width:860px) { .rate-grid { grid-template-columns:repeat(2,1fr); } }
"""

COST_JS = """\
(() => {
  const data = JSON.parse(document.getElementById('cost-data').textContent);
  const monthSelect = document.getElementById('cost-month');
  const priceSelect = document.getElementById('cost-pricing');
  const hitInput = document.getElementById('cost-hit');
  const hitLabel = document.getElementById('cost-hit-label');
  const note = document.getElementById('cost-pricing-note');
  const body = document.getElementById('cost-body');
  const totals = {
    prompt: document.getElementById('cost-total-prompt'),
    gen: document.getElementById('cost-total-gen'),
    in: document.getElementById('cost-total-in'),
    out: document.getElementById('cost-total-out'),
    total: document.getElementById('cost-total'),
  };

  function usd(value) {
    if (value >= 100) return '$' + value.toLocaleString('en-US', {maximumFractionDigits: 0});
    if (value >= 1) return '$' + value.toFixed(2);
    return '$' + value.toFixed(4);
  }
  function perM(value) {
    return '$' + (value >= 1 ? value.toFixed(2) : value.toFixed(3)) + '/M';
  }
  function tokens(value) {
    value = Math.round(value);
    if (value >= 1e9) return (value / 1e9).toFixed(2) + 'B';
    if (value >= 1e6) return (value / 1e6).toFixed(1) + 'M';
    if (value >= 1e3) return Math.round(value / 1e3) + 'K';
    return String(value);
  }
  function estimate(prompt, generation, pricing, hit) {
    const effIn = (1 - hit) * pricing.input + hit * pricing.cache_read;
    const inputCost = prompt * effIn;
    const outputCost = generation * pricing.output;
    return {inputCost, outputCost, total: inputCost + outputCost, effInPerM: effIn * 1e6};
  }
  function render() {
    const month = data.months[monthSelect.value] || {};
    const pricing = data.pricing.find(entry => entry.id === priceSelect.value) || data.pricing[0];
    const hit = Number(hitInput.value) / 100;
    hitLabel.textContent = Math.round(hit * 100) + '%';
    let sumPrompt = 0, sumGen = 0, sumIn = 0, sumOut = 0, sumTotal = 0;
    body.textContent = '';
    for (const model of data.models) {
      const usage = month[model] || {prompt: 0, generation: 0};
      const est = estimate(usage.prompt, usage.generation, pricing, hit);
      sumPrompt += usage.prompt; sumGen += usage.generation;
      sumIn += est.inputCost; sumOut += est.outputCost; sumTotal += est.total;
      const row = document.createElement('tr');
      const head = document.createElement('th');
      head.scope = 'row';
      head.textContent = model;
      row.appendChild(head);
      for (const value of [tokens(usage.prompt), tokens(usage.generation),
                           usd(est.inputCost), usd(est.outputCost), usd(est.total)]) {
        const cell = document.createElement('td');
        cell.textContent = value;
        row.appendChild(cell);
      }
      body.appendChild(row);
    }
    totals.prompt.textContent = tokens(sumPrompt);
    totals.gen.textContent = tokens(sumGen);
    totals.in.textContent = usd(sumIn);
    totals.out.textContent = usd(sumOut);
    totals.total.textContent = usd(sumTotal);
    const est = estimate(sumPrompt, sumGen, pricing, hit);
    note.textContent = pricing.note + ' · effective ' + perM(est.effInPerM) +
      ' input at ' + Math.round(hit * 100) + '% cache-hit';
  }
  monthSelect.addEventListener('change', render);
  priceSelect.addEventListener('change', render);
  hitInput.addEventListener('input', render);
  render();
})();
"""

RATE_JS = """\
(() => {
  const data = JSON.parse(document.getElementById('cost-data').textContent);
  const windowSelect = document.getElementById('rate-window');
  const tariffInput = document.getElementById('rate-tariff');
  const wattsInput = document.getElementById('rate-watts');
  const note = document.getElementById('rate-note');
  const body = document.getElementById('rate-body');
  if (!windowSelect || !data.rates) return;
  const cards = {
    gen: document.getElementById('rate-gen-h'),
    median: document.getElementById('rate-gen-median'),
    p90: document.getElementById('rate-gen-p90'),
    max: document.getElementById('rate-gen-max'),
    prompt: document.getElementById('rate-prompt-h'),
    windows: document.getElementById('rate-active-windows'),
    hours: document.getElementById('rate-active-hours'),
  };
  const deepseek = data.pricing.find(entry => entry.id === 'deepseek-v4.1-flash-official') || data.pricing[0];
  const sol = data.pricing.find(entry => entry.id === 'gpt-5.6-sol') || data.pricing[0];
  const cacheHit = data.defaultCacheHit;

  function usd(value) {
    if (value >= 100) return '$' + value.toLocaleString('en-US', {maximumFractionDigits: 0});
    if (value >= 1) return '$' + value.toFixed(2);
    return '$' + value.toFixed(3);
  }
  function num(value) { return Math.round(value).toLocaleString('en-US'); }

  function render() {
    const keys = Object.keys(data.rates);
    const rates = data.rates[windowSelect.value] || data.rates[keys[0]];
    const tariff = Number(tariffInput.value) || 0;
    const watts = Number(wattsInput.value) || 0;
    const electricity = watts / 1000 * tariff;
    cards.gen.textContent = num(rates.genPerH);
    cards.median.textContent = num(rates.genMedian);
    cards.p90.textContent = num(rates.genP90);
    cards.max.textContent = num(rates.genMax);
    cards.prompt.textContent = num(rates.promptPerH);
    cards.windows.textContent = rates.activeWindows.toLocaleString('en-US') + ' / ' +
      rates.totalWindows.toLocaleString('en-US') +
      ' (' + Math.round(rates.activeWindows / rates.totalWindows * 100) + '%)';
    cards.hours.textContent = rates.activeHours + ' of ' + Math.round(rates.periodHours) + ' h';
    const rows = [
      ['DeepSeek V4.1 Flash · peak', rates.promptPerH * deepseek.input + rates.genPerH * deepseek.output],
      ['DeepSeek V4.1 Flash · off-peak', rates.promptPerH * deepseek.input / 2 + rates.genPerH * deepseek.output / 2],
      ['DeepSeek V4.1 Flash · ' + Math.round(cacheHit * 100) + '% cache-hit',
       rates.promptPerH * ((1 - cacheHit) * deepseek.input + cacheHit * deepseek.cache_read) +
       rates.genPerH * deepseek.output],
      ['GPT-5.6 Sol · ' + Math.round(cacheHit * 100) + '% cache-hit',
       rates.promptPerH * ((1 - cacheHit) * sol.input + cacheHit * sol.cache_read) +
       rates.genPerH * sol.output],
      ['Electricity (whole box)', electricity],
    ];
    body.textContent = '';
    for (const [label, perHour] of rows) {
      const tr = document.createElement('tr');
      const th = document.createElement('th');
      th.scope = 'row';
      th.textContent = label;
      tr.appendChild(th);
      const price = document.createElement('td');
      price.textContent = usd(perHour);
      tr.appendChild(price);
      const advantage = document.createElement('td');
      advantage.textContent = label.startsWith('Electricity')
        ? '×1'
        : '×' + (perHour / electricity >= 10 ? Math.round(perHour / electricity) : (perHour / electricity).toFixed(1));
      tr.appendChild(advantage);
      body.appendChild(tr);
    }
    note.textContent = num(rates.genPerH) + ' gen/h · ' + num(rates.promptPerH) +
      ' prompt/h · ' + rates.activeWindows + ' active windows · draw ' + watts + ' W · tariff ' + tariff + '/kWh';
  }
  windowSelect.addEventListener('change', render);
  tariffInput.addEventListener('input', render);
  wattsInput.addEventListener('input', render);
  render();
})();
"""


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


def month_key(ts):
    return dt.date.fromtimestamp(ts).strftime("%Y-%m")


def latest_full_month(today):
    """The most recent complete calendar month, e.g. August while it is September."""
    first = today.replace(day=1)
    return (first - dt.timedelta(days=1)).strftime("%Y-%m")


def cost_usage(rows, models):
    """Per-model token totals bucketed by calendar month, plus an All time roll-up."""
    by_month = defaultdict(lambda: defaultdict(lambda: {"prompt": 0.0, "generation": 0.0}))
    for row in rows:
        entry = by_month[month_key(row["ts"])][row["model"]]
        entry["prompt"] += row["prompt"]
        entry["generation"] += row["generation"]
    months = {
        month: {model: per_model.get(model, {"prompt": 0.0, "generation": 0.0}) for model in models}
        for month, per_model in sorted(by_month.items())
    }
    all_time = {
        model: {
            "prompt": sum(months[month][model]["prompt"] for month in months),
            "generation": sum(months[month][model]["generation"] for month in months),
        }
        for model in models
    }
    return {"months": {**months, "__all__": all_time}, "models": list(models)}


def cost_estimate(prompt_tokens, generation_tokens, pricing, cache_hit):
    """Pure: counterfactual USD cost for a token volume under one hosted price."""
    effective_input = (1 - cache_hit) * pricing["input"] + cache_hit * pricing["cache_read"]
    input_cost = prompt_tokens * effective_input
    output_cost = generation_tokens * pricing["output"]
    return {
        "input_cost": input_cost,
        "output_cost": output_cost,
        "total": input_cost + output_cost,
        "effective_input_per_m": effective_input * 1e6,
    }


def active_window_stats(rows, days=None):
    """Hourly token rates over clean active windows, excluding idle windows and
    gap-spanning rows; days=None means all time. Returns None when the window
    has no clean active windows."""
    end_ts = max(r["ts"] for r in rows)
    cutoff = None if days is None else end_ts - days * 86400
    subset = rows if cutoff is None else [r for r in rows if r["ts"] >= cutoff]
    active = [r for r in subset if r["generation"] > 0]
    clean = [r for r in active if r["interval"] and r["interval"] <= ACTIVE_WINDOW_MAX_SECS]
    if not clean:
        return None
    per_window = sorted(r["generation"] / r["interval"] * 3600 for r in clean)
    total_gen = sum(r["generation"] for r in clean)
    total_prompt = sum(r["prompt"] for r in clean)
    total_secs = sum(r["interval"] for r in clean)
    return {
        "genPerH": total_gen / total_secs * 3600,
        "genMedian": statistics.median(per_window),
        "genP90": per_window[int(len(per_window) * 0.9)],
        "genMax": per_window[-1],
        "promptPerH": total_prompt / total_secs * 3600,
        "activeWindows": len(active),
        "totalWindows": len(subset),
        "activeHours": len({dt.datetime.fromtimestamp(r["ts"]).strftime("%Y-%m-%d %H") for r in active}),
        "periodHours": days * 24 if days is not None else (end_ts - min(r["ts"] for r in rows)) / 3600,
    }


def fmt_usd(value):
    if value >= 100:
        return f"${value:,.0f}"
    if value >= 1:
        return f"${value:,.2f}"
    return f"${value:.4f}"


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


def month_option(key, default_month):
    label = "All time" if key == "__all__" else f"{MONTHS[int(key[5:7]) - 1]} {key[:4]}"
    selected = " selected" if key == default_month else ""
    return f'<option value="{key}"{selected}>{label}</option>'


def cost_section(cost_blob, default_month):
    """Server-rendered default state; JS re-renders from the embedded blob on input."""
    pricing = PRICING[0]
    month_data = cost_blob["months"][default_month]
    rows_html = []
    totals = {"prompt": 0.0, "generation": 0.0, "in": 0.0, "out": 0.0, "total": 0.0}
    for model in cost_blob["models"]:
        usage = month_data[model]
        estimate = cost_estimate(usage["prompt"], usage["generation"], pricing, DEFAULT_CACHE_HIT)
        totals["prompt"] += usage["prompt"]
        totals["generation"] += usage["generation"]
        totals["in"] += estimate["input_cost"]
        totals["out"] += estimate["output_cost"]
        totals["total"] += estimate["total"]
        rows_html.append(
            '<tr><th scope="row">' + html.escape(model) + '</th>'
            f'<td>{fmt(usage["prompt"])}</td><td>{fmt(usage["generation"])}</td>'
            f'<td>{fmt_usd(estimate["input_cost"])}</td><td>{fmt_usd(estimate["output_cost"])}</td>'
            f'<td>{fmt_usd(estimate["total"])}</td></tr>'
        )
    eff_per_m = cost_estimate(1_000_000, 0, pricing, DEFAULT_CACHE_HIT)["effective_input_per_m"]
    eff_text = f"${eff_per_m:.2f}" if eff_per_m >= 1 else f"${eff_per_m:.3f}"
    note = (
        f"{pricing['note']} · effective {eff_text}/M input at {DEFAULT_CACHE_HIT:.0%} cache-hit"
    )
    real_months = sorted(key for key in cost_blob["months"] if key != "__all__")
    month_options = "".join(month_option(key, default_month) for key in [*real_months, "__all__"])
    pricing_options = "".join(
        f'<option value="{entry["id"]}"{" selected" if entry is pricing else ""}>'
        f'{html.escape(entry["label"])}</option>'
        for entry in PRICING
    )
    return f'''
<section class="cost">
  <h2>Cloud cost counterfactual</h2>
  <p>What the recorded usage — self-hosted at $0 in API fees — would have billed through a hosted API. Engine prompt counters include prefix-cache re-reads, so cached prefixes bill at the cache-read rate; the cache-hit slider states that assumption. Prices: {PRICING_SOURCE}, as of {PRICING_AS_OF}.</p>
  <div class="cost-controls">
    <label>Month <select id="cost-month">{month_options}</select></label>
    <label>Priced as <select id="cost-pricing">{pricing_options}</select></label>
    <label>Cache-hit <input type="range" id="cost-hit" min="0" max="100" step="5" value="{int(DEFAULT_CACHE_HIT * 100)}"><output id="cost-hit-label">{DEFAULT_CACHE_HIT:.0%}</output></label>
    <span class="pricing-note" id="cost-pricing-note">{html.escape(note)}</span>
  </div>
  <div class="table-wrap"><table>
    <thead><tr><th>Model</th><th>Prompt</th><th>Generated</th><th>Input cost</th><th>Output cost</th><th>Est. bill</th></tr></thead>
    <tbody id="cost-body">{"".join(rows_html)}</tbody>
    <tfoot><tr><th scope="row">Total</th><td id="cost-total-prompt">{fmt(totals["prompt"])}</td><td id="cost-total-gen">{fmt(totals["generation"])}</td><td id="cost-total-in">{fmt_usd(totals["in"])}</td><td id="cost-total-out">{fmt_usd(totals["out"])}</td><td id="cost-total">{fmt_usd(totals["total"])}</td></tr></tfoot>
  </table></div>
</section>'''


def rate_window_option(key, default):
    labels = {"7": "Last 7 days", "14": "Last 14 days", "30": "Last 30 days", "__all__": "All time"}
    selected = " selected" if key == default else ""
    return f'<option value="{key}"{selected}>{labels[key]}</option>'


def rate_section(rates_blob):
    """Server-rendered default state; JS re-renders from the embedded blob on input."""
    if not rates_blob:
        return ""
    order = ["7", "14", "30", "__all__"]
    available = [key for key in order if key in rates_blob]
    default = available[0]
    rates = rates_blob[default]
    official = next(entry for entry in PRICING if entry["id"] == "deepseek-v4.1-flash-official")
    sol = next(entry for entry in PRICING if entry["id"] == "gpt-5.6-sol")
    electricity = POWER_DRAW_WATTS / 1000 * DEFAULT_TARIFF
    rows = [
        ("DeepSeek V4.1 Flash · peak",
         rates["promptPerH"] * official["input"] + rates["genPerH"] * official["output"]),
        ("DeepSeek V4.1 Flash · off-peak",
         rates["promptPerH"] * official["input"] / 2 + rates["genPerH"] * official["output"] / 2),
        ("DeepSeek V4.1 Flash · 80% cache-hit",
         cost_estimate(rates["promptPerH"], rates["genPerH"], official, DEFAULT_CACHE_HIT)["total"]),
        ("GPT-5.6 Sol · 80% cache-hit",
         cost_estimate(rates["promptPerH"], rates["genPerH"], sol, DEFAULT_CACHE_HIT)["total"]),
        ("Electricity (whole box)", electricity),
    ]
    body = []
    for label, per_hour in rows:
        ratio = per_hour / electricity if electricity > 0 else 1
        advantage = "×1" if label.startswith("Electricity") else (
            f"×{ratio:.0f}" if ratio >= 10 else f"×{ratio:.1f}"
        )
        body.append(
            '<tr><th scope="row">' + html.escape(label) + '</th>'
            f'<td>{fmt_usd(per_hour)}</td><td>{advantage}</td></tr>'
        )
    window_options = "".join(rate_window_option(key, default) for key in available)
    note = (
        f"{rates['genPerH']:,.0f} gen/h · {rates['promptPerH']:,.0f} prompt/h · "
        f"{rates['activeWindows']} active windows · draw {POWER_DRAW_WATTS} W · tariff {DEFAULT_TARIFF}/kWh"
    )
    return f'''
<section class="rates-section">
  <h2>Active-hour rate &amp; electricity</h2>
  <p>Tokens per hour over clean active windows only — idle windows and gap-spanning rows (downtime inside an interval) are excluded, so this is the serving rate, not wall-clock throughput. Electricity prices the measured serving draw against your tariff; the box draws it continuously while up (vLLM busy-polls keep the GPUs loaded between requests).</p>
  <div class="cost-controls">
    <label>Window <select id="rate-window">{window_options}</select></label>
    <label>Draw <input type="number" id="rate-watts" min="0" step="10" value="{POWER_DRAW_WATTS}"> W</label>
    <label>Tariff <input type="number" id="rate-tariff" min="0" step="0.01" value="{DEFAULT_TARIFF}"> /kWh</label>
    <span class="pricing-note" id="rate-note">{html.escape(note)}</span>
  </div>
  <div class="rate-grid">
    <div class="rate-card"><strong id="rate-gen-h">{rates['genPerH']:,.0f}</strong><span>Generated · per active hour</span><span class="sub">median <span id="rate-gen-median">{rates['genMedian']:,.0f}</span> · p90 <span id="rate-gen-p90">{rates['genP90']:,.0f}</span> · max <span id="rate-gen-max">{rates['genMax']:,.0f}</span></span></div>
    <div class="rate-card"><strong id="rate-prompt-h">{rates['promptPerH']:,.0f}</strong><span>Prompt · per active hour</span></div>
    <div class="rate-card"><strong id="rate-active-windows">{rates['activeWindows']} / {rates['totalWindows']}</strong><span>Active windows</span></div>
    <div class="rate-card"><strong id="rate-active-hours">{rates['activeHours']} of {rates['periodHours']:.0f} h</strong><span>Active clock-hours</span></div>
  </div>
  <div class="table-wrap"><table>
    <thead><tr><th>Per active hour</th><th>$/h</th><th>Box advantage</th></tr></thead>
    <tbody id="rate-body">{"".join(body)}</tbody>
  </table></div>
</section>'''


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
    cost_blob = cost_usage(rows, models)
    default_month = latest_full_month(today)
    if default_month not in cost_blob["months"]:
        fallback = [key for key in cost_blob["months"] if key != "__all__"]
        default_month = max(fallback) if fallback else None
    cost_html = ""
    cost_total = 0.0
    if default_month:
        cost_html = cost_section(cost_blob, default_month)
        month_data = cost_blob["months"][default_month]
        cost_total = cost_estimate(
            sum(month_data[model]["prompt"] for model in cost_blob["models"]),
            sum(month_data[model]["generation"] for model in cost_blob["models"]),
            PRICING[0],
            DEFAULT_CACHE_HIT,
        )["total"]
    rates_blob = {
        ("__all__" if days is None else str(days)): stats
        for days in (7, 14, 30, None)
        if (stats := active_window_stats(rows, days)) is not None
    }
    cost_json = json.dumps(
        {
            "months": cost_blob["months"],
            "models": cost_blob["models"],
            "pricing": PRICING,
            "pricingSource": PRICING_SOURCE,
            "pricingAsOf": PRICING_AS_OF,
            "rates": rates_blob,
            "powerWatts": POWER_DRAW_WATTS,
            "defaultTariff": DEFAULT_TARIFF,
            "defaultCacheHit": DEFAULT_CACHE_HIT,
        },
        ensure_ascii=False,
    ).replace("<", "\\u003c").replace(">", "\\u003e")
    cost_scripts = (
        f'<script type="application/json" id="cost-data">{cost_json}</script>\n'
        f'<script>\n{COST_JS}\n{RATE_JS}</script>'
    )
    rate_html = rate_section(rates_blob) if rates_blob else ""
    default_rate_key = next((key for key in ("7", "14", "30", "__all__") if key in rates_blob), "")
    default_rate = rates_blob.get(default_rate_key, {}).get("genPerH", 0.0)

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
  {COST_CSS}{RATE_CSS}
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
  {cost_html}
  {rate_html}
  <section class="explain">
    <h2>How to read this page</h2>
    <p><strong>Durable totals:</strong> engine counters reset whenever a container restarts or the runtime changes. This ledger records counter deltas to disk and continues across vLLM, SGLang, restarts, and engine switches.</p>
    <p><strong>Model history:</strong> known historical intervals are assigned only from explicit runtime evidence. Genuinely unsplittable rows remain under <em>{LEGACY_MODEL}</em>; they are included in All models but never guessed into a model.</p>
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
{cost_scripts}
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
        "cost_month": default_month or "",
        "cost_label": PRICING[0]["label"],
        "cost_total": int(round(cost_total)),
        "rate_gen_per_h": int(round(default_rate)),
        "rate_window": default_rate_key,
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
    if summary["cost_month"]:
        print(
            f"cloud counterfactual: {summary['cost_label']} · {summary['cost_month']} · "
            f"{fmt_usd(summary['cost_total'])}"
        )
    if summary["rate_window"]:
        print(
            f"active-hour rate: {summary['rate_gen_per_h']:,} gen/h · "
            f"clean active windows, {summary['rate_window']}d"
        )
    if args.write:
        print(f"stats page written to {output}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
