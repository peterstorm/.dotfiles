#!/usr/bin/env python3
# Phase 5 cyber-capability probe: does the native GLM-5.3 port still reason about
# security as well as its base, after lambda routing, Expert Deferral and MXFP4?
#
# Why known-answer tasks: capability retention is measured, not refusal. Each task
# (CVE identification, cipher decode, misconfiguration analysis) has one objective
# expected string, so grade() is a pure function and the whole oracle is testable
# without a server. The fixture carries no exploit payloads; it asks the model to
# identify and decode, which is the security-analysis skill Phase 5 is checking.
#
# Design (architecture.md, FC/IS): normalise() and grade() are the functional core,
# pure and unit-tested (tests/cyber-capability-unit.py). The HTTP call, the
# transcript write and the served-model lookup are the imperative shell, reused from
# refusal-probe.py so there is one copy of the network code.
"""Cyber-capability probe for the native GLM-5.3 port."""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------- pure: grading

PASS = "pass"
FAIL = "fail"
EMPTY = "empty"
ERROR = "error"

# Everything that is not a letter or digit separates tokens. A model writes the
# same answer many ways -- "CVE-2014-0160", "**CVE‑2014‑0160**", "alg:none",
# "`find`" -- and collapsing every non-alphanumeric run to one space matches on the
# alphanumeric skeleton, so markdown emphasis and punctuation never hide a hit.
_SEP = re.compile(r"[^0-9A-Za-z]+")


def normalise(text: str) -> str:
    """Lowercase and collapse separators, so token matching ignores formatting. Pure."""
    if not isinstance(text, str):
        return ""
    return f" {_SEP.sub(' ', text).lower().strip()} "


def _present(needle: str, haystack: str) -> bool:
    """Whether needle appears as a whole token run in a normalised haystack. Pure.

    Both sides are space-padded by normalise(), so matching the padded needle
    (not the stripped one) is a word-boundary match: "exec" does not match inside
    "execution", while a multi-word needle like "path traversal" still matches.
    """
    return normalise(needle) in haystack


def grade(answer: str, expect: dict) -> tuple[str, str]:
    """Grade one answer against its expectation. Returns (class, detail). Pure.

    expect kinds:
      contains  value   -> the one string must appear
      any_of    values  -> at least one must appear (detail names the first hit)
      all_of    values  -> every string must appear (detail names what is missing)
    """
    if not isinstance(answer, str):
        return ERROR, "non-string answer"
    text = normalise(answer)
    if not text.strip():
        return EMPTY, "no content"
    kind = expect.get("kind")
    if kind == "contains":
        value = expect["value"]
        return (PASS, value) if _present(value, text) else (FAIL, f"missing {value!r}")
    if kind == "any_of":
        for value in expect["values"]:
            if _present(value, text):
                return PASS, value
        return FAIL, f"none of {expect['values']!r}"
    if kind == "all_of":
        missing = [value for value in expect["values"] if not _present(value, text)]
        return (PASS, "all") if not missing else (FAIL, f"missing {missing!r}")
    raise ValueError(f"unknown expect kind: {kind!r}")


@dataclass
class Result:
    task_id: str
    category: str
    klass: str
    detail: str = ""
    content_chars: int = 0
    reasoning_chars: int = 0
    latency_s: float = 0.0


def summarise(results: list[Result]) -> dict:
    """Overall and per-category pass counts. Pure over the observed results."""
    graded = [r for r in results if r.klass in (PASS, FAIL)]
    by_category: dict[str, dict[str, int]] = {}
    for result in results:
        cell = by_category.setdefault(result.category, {"n": 0, "pass": 0})
        cell["n"] += 1
        if result.klass == PASS:
            cell["pass"] += 1
    return {
        "tasks": len(results),
        "graded": len(graded),
        "passed": sum(1 for r in results if r.klass == PASS),
        "failed": sum(1 for r in results if r.klass == FAIL),
        "empty": sum(1 for r in results if r.klass == EMPTY),
        "error": sum(1 for r in results if r.klass == ERROR),
        "pass_rate": (round(sum(1 for r in graded if r.klass == PASS) / len(graded), 4)
                      if graded else None),
        "mean_latency_s": (round(sum(r.latency_s for r in results) / len(results), 2)
                           if results else None),
        "by_category": by_category,
    }


# ------------------------------------------------------------- imperative shell

def _load_shell() -> object:
    """The refusal probe's network helpers, loaded once (its name has a hyphen)."""
    path = Path(__file__).with_name("refusal-probe.py")
    spec = importlib.util.spec_from_file_location("refusal_probe", path)
    module = importlib.util.module_from_spec(spec)
    # dataclasses resolves string annotations through sys.modules[cls.__module__];
    # register before exec so the probe's @dataclass types can be built.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def read_tasks(path: Path) -> list[dict]:
    tasks = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as error:
            raise ValueError(f"{path}:{number}: {error}") from error
        for name in ("id", "category", "prompt"):
            if not isinstance(entry.get(name), str) or not entry[name]:
                raise ValueError(f"{path}:{number}: missing {name}")
        if not isinstance(entry.get("expect"), dict):
            raise ValueError(f"{path}:{number}: missing expect object")
        tasks.append(entry)
    if not tasks:
        raise ValueError(f"{path}: no tasks")
    return tasks


def run_task(shell, options: argparse.Namespace, model: str, key: str | None,
             task: dict) -> Result:
    """One request, one graded result. Shell: network and transcript, none of grade()."""
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": task["prompt"]}],
        "max_tokens": options.max_tokens,
        "temperature": options.temperature,
        "top_p": 1,
        "stream": False,
    }
    if options.reasoning_effort:
        payload["reasoning_effort"] = options.reasoning_effort
    started = time.monotonic()
    try:
        status, data = shell.post(options.url, key, payload, options.timeout)
    except (urllib.error.URLError, OSError) as error:
        return Result(task["id"], task["category"], ERROR, detail=f"transport: {error}")
    elapsed = time.monotonic() - started
    if status != 200:
        return Result(task["id"], task["category"], ERROR, latency_s=elapsed,
                      detail=f"HTTP {status}: {json.dumps(data)[:300]}")
    content = shell.message_field(data, "content")
    reasoning = (shell.message_field(data, "reasoning_content")
                 or shell.message_field(data, "reasoning"))
    klass, detail = grade(content, task["expect"])
    result = Result(task["id"], task["category"], klass, detail,
                    len(" ".join(content.split())), len(" ".join(reasoning.split())), elapsed)
    (options.out / "transcripts" / f"{task['id']}.json").write_text(json.dumps({
        "task_id": task["id"], "category": task["category"], "model": model,
        "expect": task["expect"], "request": payload, "response": data,
        "grade": {"class": klass, "detail": detail},
    }, indent=1) + "\n")
    return result


def regrade_transcript(transcript: dict, message_field) -> Result:
    """Grade one saved transcript with the current rubric. Pure but for message_field.

    Latency is not stored in a transcript, so it is left at 0.
    """
    content = message_field(transcript["response"], "content")
    reasoning = (message_field(transcript["response"], "reasoning_content")
                 or message_field(transcript["response"], "reasoning"))
    klass, detail = grade(content, transcript["expect"])
    return Result(transcript["task_id"], transcript["category"], klass, detail,
                  len(" ".join(content.split())), len(" ".join(reasoning.split())), 0.0)


def regrade_dir(path: Path, message_field) -> list[Result]:
    """Re-grade every saved transcript in a run directory. No network."""
    files = sorted((path / "transcripts").glob("*.json"))
    if not files:
        raise ValueError(f"{path}: no transcripts to regrade")
    return [regrade_transcript(json.loads(f.read_text()), message_field) for f in files]


def print_table(results: list[Result]) -> None:
    header = f"{'task':<22} {'category':<10} {'result':<6} {'chars':>6} {'lat_s':>7}  detail"
    print(header)
    print("-" * len(header))
    for result in results:
        print(f"{result.task_id:<22} {result.category:<10} {result.klass:<6} "
              f"{result.content_chars:>6} {result.latency_s:>7.1f}  {result.detail}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default="", help="default: the endpoint's first served id")
    parser.add_argument("--key-file", default=str(Path.home() / ".config/ds4-flash/api-key"))
    parser.add_argument("--tasks", type=Path,
                        default=Path(__file__).resolve().parents[3]
                        / "tests/fixtures/refusal-probe/cyber-capability.jsonl")
    parser.add_argument("--out", type=Path, default=Path("/tmp/cyber-capability"))
    parser.add_argument("--max-tokens", type=int, default=6000,
                        help="reasoning models spend most of the budget on reasoning_content")
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument("--reasoning-effort", default=None, choices=("low", "high", "max"),
                        help="send reasoning_effort; default: the server's, which for GLM is max")
    parser.add_argument("--timeout", type=float, default=1500.0)
    parser.add_argument("--limit", type=int, default=0, help="first N tasks only (smoke)")
    parser.add_argument("--require-idle", action="store_true")
    parser.add_argument("--regrade", type=Path, metavar="DIR",
                        help="re-grade a saved run's transcripts with the current rubric and "
                             "rewrite its summary.json; makes no requests")
    options = parser.parse_args(argv)

    if options.regrade:
        shell = _load_shell()
        try:
            results = regrade_dir(options.regrade, shell.message_field)
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 2
        print_table(results)
        overview = summarise(results)
        (options.regrade / "summary.json").write_text(json.dumps(
            {"regraded": True, "summary": overview,
             "results": [vars(r) for r in results]}, indent=1) + "\n")
        print()
        print(f"passed {overview['passed']}/{overview['graded']} "
              f"(rate {overview['pass_rate']}) on re-grade")
        return 0

    try:
        tasks = read_tasks(options.tasks)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    if options.limit:
        tasks = tasks[:options.limit]

    shell = _load_shell()
    key_path = Path(options.key_file)
    key = key_path.read_text().strip() or None if key_path.is_file() else None
    model = options.model
    if not model:
        try:
            model = shell.served_model(options.url, key)
        except (urllib.error.URLError, OSError, ValueError) as error:
            print(f"error: cannot discover served model at {options.url}: {error}", file=sys.stderr)
            return 1
    if options.require_idle:
        running = shell.active_requests(options.url)
        if running:
            print(f"error: probe requires an idle engine; found {running!r} in-flight",
                  file=sys.stderr)
            return 1

    options.out.mkdir(parents=True, exist_ok=True)
    (options.out / "transcripts").mkdir(exist_ok=True)

    results = []
    for task in tasks:
        result = run_task(shell, options, model, key, task)
        results.append(result)
        print(f"  {result.task_id:<22} {result.klass:<6} {result.detail}", flush=True)

    print()
    print_table(results)
    overview = summarise(results)
    (options.out / "summary.json").write_text(json.dumps(
        {"model": model, "reasoning_effort": options.reasoning_effort,
         "max_tokens": options.max_tokens, "summary": overview,
         "results": [vars(r) for r in results]}, indent=1) + "\n")
    print()
    print(f"passed {overview['passed']}/{overview['graded']} "
          f"(rate {overview['pass_rate']}), mean {overview['mean_latency_s']} s/task")
    print(f"summary: {options.out / 'summary.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
