#!/usr/bin/env python3
"""Qualification-gate harness for a GLM-5.3 Flash profile on :8000 (vLLM).

Mirrors the v10 qualification receipt cell for cell so numbers are comparable:
text, determinism, vision, MTP counters, shared prefix, mixed traffic, exact
retrieval at 128K/261.9K/358.9K, C1 and long-context throughput cells, and a
sustained soak. Adds one r2.1-specific gate: shared-prefix session churn under
a concurrent whale, watching cached_tokens and the reserve aging escape.

Stdlib only. Results append as JSON lines to RESULTS (one object per gate) and
a human log goes to stdout. Phases: smoke correctness capabilities retrieval
throughput soak all.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import random
import struct
import sys
import threading
import time
import urllib.error
import urllib.request
import zlib

BASE = os.environ.get("BASE_URL", "http://127.0.0.1:8000")
MODEL = os.environ["MODEL"]
KEY = open(os.path.expanduser(os.environ.get("KEYFILE", "~/.config/glm53/api-key"))).read().strip()
RESULTS = os.environ.get("RESULTS", "/tmp/v111-gates.jsonl")
SOAK_SECONDS = int(os.environ.get("SOAK_SECONDS", "1800"))
NO_THINK = {"thinking": False, "enable_thinking": False}

FILLER = (
    "Sentence {i}: the amber kettle whispered of {a} cups of quiet, while the "
    "{b}th window held the afternoon light against the paper map. "
)


def log(msg: str) -> None:
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


def record(gate: str, **fields) -> None:
    row = {"gate": gate, "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), **fields}
    with open(RESULTS, "a") as fh:
        fh.write(json.dumps(row) + "\n")
    log(f"[{gate}] {'PASS' if row.get('ok') else 'FAIL'} " + json.dumps({k: v for k, v in fields.items() if k != 'ok'}))


def post(payload: dict, timeout: float = 1800) -> dict:
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


def chat(content, max_tokens=64, think=False, temperature=0.0, seed=None, timeout=1800, extra=None) -> dict:
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if not think:
        payload["chat_template_kwargs"] = NO_THINK
    if seed is not None:
        payload["seed"] = seed
        payload["top_p"] = 1.0
    if extra:
        payload.update(extra)
    return post(payload, timeout=timeout)


def stream(content, max_tokens, think=True, timeout=1800) -> dict:
    """Stream one completion; return TTFT, wall, usage, first/last token times."""
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if not think:
        payload["chat_template_kwargs"] = NO_THINK
    req = urllib.request.Request(
        f"{BASE}/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"},
    )
    start = time.monotonic()
    first = None
    last = None
    usage = None
    finish = None
    deltas: list[float] = []
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        for raw in resp:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            obj = json.loads(data)
            if obj.get("usage"):
                usage = obj["usage"]
            for ch in obj.get("choices", []):
                d = ch.get("delta", {})
                if d.get("content") or d.get("reasoning_content") or d.get("reasoning"):
                    now = time.monotonic()
                    if first is None:
                        first = now
                    elif last is not None:
                        deltas.append(now - last)
                    last = now
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
    end = time.monotonic()
    deltas.sort()
    p = lambda q: (deltas[min(len(deltas) - 1, int(len(deltas) * q))] * 1000) if deltas else None
    comp = (usage or {}).get("completion_tokens", 0)
    return {
        "ttft_s": round((first - start), 3) if first else None,
        "wall_s": round(end - start, 3),
        "completion_tokens": comp,
        "prompt_tokens": (usage or {}).get("prompt_tokens"),
        "finish": finish,
        "decode_tok_s": round((comp - 1) / (last - first), 1) if (first and last and last > first and comp > 1) else None,
        "overall_tok_s": round(comp / (end - start), 1) if comp else None,
        "itl_p50_ms": round(p(0.5), 1) if deltas else None,
        "itl_p95_ms": round(p(0.95), 1) if deltas else None,
    }


def metrics() -> dict[str, float]:
    with urllib.request.urlopen(f"{BASE}/metrics", timeout=10) as resp:
        out: dict[str, float] = {}
        for line in resp.read().decode().splitlines():
            if line.startswith("vllm:") and " " in line:
                name, val = line.rsplit(" ", 1)
                key = name.split("{", 1)[0]
                if "finished_reason=" in name:
                    key += "[" + name.split('finished_reason="', 1)[1].split('"', 1)[0] + "]"
                try:
                    out[key] = out.get(key, 0.0) + float(val)
                except ValueError:
                    pass
        return out


def message_text(resp: dict) -> str:
    m = resp["choices"][0]["message"]
    return (m.get("content") or "").strip()


# --- prompt construction --------------------------------------------------
_TOK_PER_LINE: float | None = None


def filler_lines(n: int, salt: int = 0) -> str:
    return "".join(FILLER.format(i=i + salt, a=(i + salt) % 97, b=(i + salt) % 53) for i in range(1, n + 1))


def calibrate() -> float:
    """Tokens per filler line on this tokenizer (usage.prompt_tokens based)."""
    global _TOK_PER_LINE
    if _TOK_PER_LINE is None:
        n = 2000
        r = chat(filler_lines(n) + " Reply with the single word DONE.", max_tokens=4)
        _TOK_PER_LINE = r["usage"]["prompt_tokens"] / n
        log(f"calibration: {r['usage']['prompt_tokens']} prompt tokens for {n} lines -> {_TOK_PER_LINE:.3f} tok/line")
    return _TOK_PER_LINE


def retrieval_prompt(target_tokens: int, code: str, salt: int = 0) -> str:
    """Filler sized to ~target_tokens with the code buried at the midpoint."""
    per = calibrate()
    n = int(target_tokens / per) - 20
    half = n // 2
    return (
        filler_lines(half, salt)
        + f" IMPORTANT: the secret access code is {code}. Remember it. "
        + filler_lines(n - half, salt + half)
        + " Question: what is the secret access code? Reply with only the code and nothing else."
    )


def new_code() -> str:
    return "QX-" + "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(8))


def red_png(size: int = 32) -> str:
    raw = b"".join(b"\x00" + b"\xff\x00\x00" * size for _ in range(size))
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    return "data:image/png;base64," + base64.b64encode(png).decode()


# --- gates ----------------------------------------------------------------
def gate_text() -> None:
    r = chat("Reply with exactly the text TEXT_OK and nothing else.", max_tokens=16)
    record("text", ok=message_text(r) == "TEXT_OK", content=message_text(r), usage=r["usage"])


def gate_determinism(n: int = 10) -> None:
    prompt = "Write a 120-word paragraph about how a hash table resolves collisions."
    hashes_full, hashes_content = set(), set()
    for _ in range(n):
        r = chat(prompt, max_tokens=256, think=True, temperature=0.0, seed=0)
        m = r["choices"][0]["message"]
        hashes_full.add(hashlib.sha256(json.dumps({"c": m.get("content"), "r": m.get("reasoning_content")}, sort_keys=True).encode()).hexdigest())
        hashes_content.add(hashlib.sha256((m.get("content") or "").encode()).hexdigest())
    record("determinism", ok=len(hashes_full) == 1, runs=n, distinct_full=len(hashes_full), distinct_content=len(hashes_content), sha256=sorted(hashes_full)[0] if len(hashes_full) == 1 else sorted(hashes_full))


def gate_vision() -> None:
    r = post({
        "model": MODEL,
        "max_tokens": 8,
        "temperature": 0,
        "chat_template_kwargs": NO_THINK,
        "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": red_png()}},
            {"type": "text", "text": "What single colour is this image? Reply with one lowercase word."},
        ]}],
    })
    txt = message_text(r).lower().strip(". ")
    record("vision", ok="red" in txt, content=txt, image_tokens=(r["usage"].get("prompt_tokens_details") or {}).get("multimodal_tokens"), usage=r["usage"])


def gate_mtp() -> None:
    before = metrics()
    r = chat("Explain how a hash table works, then give a short Python example of linear probing.", max_tokens=400, think=True, temperature=0.7)
    after = metrics()
    drafts = after.get("vllm:spec_decode_num_drafts_total", 0) - before.get("vllm:spec_decode_num_drafts_total", 0)
    acc = after.get("vllm:spec_decode_num_accepted_tokens_total", 0) - before.get("vllm:spec_decode_num_accepted_tokens_total", 0)
    record("mtp", ok=drafts > 0 and acc > 0, drafts=drafts, accepted=acc, mean_acceptance_len=round((acc + drafts) / drafts, 2) if drafts else None, completion_tokens=r["usage"]["completion_tokens"])


def gate_shared_prefix() -> None:
    per = calibrate()
    prefix = filler_lines(int(124_000 / per), salt=7_000_000)
    codes = [new_code() for _ in range(3)]
    def body(i: int) -> str:
        return prefix + filler_lines(int(3_500 / per), salt=8_000_000 + i * 10_000) + f" IMPORTANT: record {i} has value {codes[i]}. Question: what is the value of record {i}? Reply with only the value."
    warm = chat(prefix + " Reply with the single word READY.", max_tokens=4)
    results: list[dict] = [None] * 3  # type: ignore[list-item]
    def run(i: int) -> None:
        r = chat(body(i), max_tokens=24)
        results[i] = {"prompt_tokens": r["usage"]["prompt_tokens"], "cached_tokens": (r["usage"].get("prompt_tokens_details") or {}).get("cached_tokens"), "exact": message_text(r) == codes[i], "got": message_text(r)}
    threads = [threading.Thread(target=run, args=(i,)) for i in range(3)]
    t0 = time.monotonic(); [t.start() for t in threads]; [t.join() for t in threads]
    record("shared_prefix", ok=all(x["exact"] for x in results), warm_prompt_tokens=warm["usage"]["prompt_tokens"], requests=results, wall_s=round(time.monotonic() - t0, 2))


def gate_mixed_traffic() -> None:
    code = new_code()
    prompt = retrieval_prompt(256_000, code, salt=9_000_000)
    out: dict = {}
    def retrieval() -> None:
        t0 = time.monotonic(); r = chat(prompt, max_tokens=24); out["retrieval"] = {"exact": message_text(r) == code, "got": message_text(r), "prompt_tokens": r["usage"]["prompt_tokens"], "wall_s": round(time.monotonic() - t0, 2)}
    def decode() -> None:
        t0 = time.monotonic(); r = chat("Write a long, detailed essay on the history of cartography.", max_tokens=2048, think=True, temperature=0.7); out["decode_2048"] = {"completion_tokens": r["usage"]["completion_tokens"], "finish": r["choices"][0]["finish_reason"], "wall_s": round(time.monotonic() - t0, 2)}
    def short(k: int) -> None:
        time.sleep(5 * k); t0 = time.monotonic(); r = chat(f"Reply with exactly the text SHORT_{k}_OK.", max_tokens=16); out[f"short_{k}"] = {"exact": message_text(r) == f"SHORT_{k}_OK", "wall_s": round(time.monotonic() - t0, 2)}
    threads = [threading.Thread(target=retrieval), threading.Thread(target=decode), threading.Thread(target=short, args=(1,)), threading.Thread(target=short, args=(2,))]
    [t.start() for t in threads]; [t.join() for t in threads]
    ok = out["retrieval"]["exact"] and out["decode_2048"]["completion_tokens"] >= 1024 and out["short_1"]["exact"] and out["short_2"]["exact"]
    record("mixed_traffic", ok=ok, **out)


def gate_prefix_churn() -> None:
    """r2.1-specific: shared-prefix sessions keep their cache hits while a whale churns."""
    per = calibrate()
    prefix = filler_lines(int(30_000 / per), salt=11_000_000)
    whale_prompt = retrieval_prompt(272_000, new_code(), salt=12_000_000)
    turns: list[dict] = []
    lock = threading.Lock()
    def session(s: int) -> None:
        history = [{"role": "user", "content": prefix + f" Session {s}. Reply with the single word READY."}]
        r = post({"model": MODEL, "messages": history, "max_tokens": 4, "temperature": 0, "chat_template_kwargs": NO_THINK})
        history.append({"role": "assistant", "content": message_text(r)})
        for turn in range(1, 6):
            history.append({"role": "user", "content": f"Turn {turn}: reply with exactly the text T{s}_{turn}_OK."})
            r = post({"model": MODEL, "messages": history, "max_tokens": 16, "temperature": 0, "chat_template_kwargs": NO_THINK})
            history.append({"role": "assistant", "content": message_text(r)})
            with lock:
                turns.append({"session": s, "turn": turn, "prompt_tokens": r["usage"]["prompt_tokens"], "cached_tokens": (r["usage"].get("prompt_tokens_details") or {}).get("cached_tokens"), "exact": message_text(r) == f"T{s}_{turn}_OK"})
    whale: dict = {}
    def run_whale() -> None:
        time.sleep(3); t0 = time.monotonic(); r = chat(whale_prompt, max_tokens=24); whale.update(prompt_tokens=r["usage"]["prompt_tokens"], wall_s=round(time.monotonic() - t0, 2))
    m0 = metrics()
    threads = [threading.Thread(target=session, args=(s,)) for s in range(3)] + [threading.Thread(target=run_whale)]
    [t.start() for t in threads]; [t.join() for t in threads]
    m1 = metrics()
    hit_frac = [t["cached_tokens"] / t["prompt_tokens"] for t in turns if t["cached_tokens"] is not None and t["prompt_tokens"]]
    record("prefix_churn", ok=all(t["exact"] for t in turns) and min(hit_frac, default=0) >= 0.9, turns=len(turns), min_hit_fraction=round(min(hit_frac), 3) if hit_frac else None, mean_hit_fraction=round(sum(hit_frac) / len(hit_frac), 3) if hit_frac else None, whale=whale, preemptions=m1.get("vllm:num_preemptions_total", 0) - m0.get("vllm:num_preemptions_total", 0))


def gate_retrieval() -> None:
    for target in (128_000, 261_900, 358_900):
        code = new_code()
        prompt = retrieval_prompt(target, code, salt=13_000_000 + target)
        t0 = time.monotonic()
        try:
            r = chat(prompt, max_tokens=24)
        except urllib.error.HTTPError as e:
            record(f"retrieval_{target}", ok=False, error=e.read().decode()[:300]); continue
        record(f"retrieval_{target}", ok=message_text(r) == code, target_tokens=target, prompt_tokens=r["usage"]["prompt_tokens"], got=message_text(r), wall_s=round(time.monotonic() - t0, 2))


def gate_throughput() -> None:
    short = "Explain how a hash table works, then give a short Python example of a linear-probing implementation. Keep it under 300 words."
    runs = [stream(short, 800) for _ in range(3)]
    record("c1", ok=all(r["completion_tokens"] == 800 for r in runs), runs=runs, median_overall_tok_s=sorted(r["overall_tok_s"] for r in runs)[1])
    for target in (32_000, 128_000, 256_000):
        prompt = retrieval_prompt(target, new_code(), salt=14_000_000 + target) + " Then explain the history of cartography at length."
        r = stream(prompt, 512, think=True)
        record(f"cell_{target}", ok=r["completion_tokens"] == 512, **r)


def gate_soak() -> None:
    per = calibrate()
    stop = time.monotonic() + SOAK_SECONDS
    counts = {"requests": 0, "prompt_tokens": 0, "completion_tokens": 0, "errors": 0}
    lock = threading.Lock()
    def account(r: dict | None, err: str | None = None) -> None:
        with lock:
            if err:
                counts["errors"] += 1; log("soak error: " + err[:200])
            else:
                counts["requests"] += 1; counts["prompt_tokens"] += r["usage"]["prompt_tokens"]; counts["completion_tokens"] += r["usage"]["completion_tokens"]
    def prefill_stream() -> None:
        k = 0
        while time.monotonic() < stop:
            k += 1
            prompt = filler_lines(int(32_000 / per), salt=20_000_000 + k * 100_000) + " Summarise the text above in a few sentences."
            try: account(chat(prompt, max_tokens=128, think=True, temperature=0.7))
            except Exception as e: account(None, repr(e))
    def decode_stream(s: int) -> None:
        while time.monotonic() < stop:
            try: account(chat(f"Stream {s}: write a detailed paragraph about {random.choice(['glaciers', 'compilers', 'coral reefs', 'lighthouses', 'sorting networks'])}.", max_tokens=256, think=True, temperature=0.7))
            except Exception as e: account(None, repr(e))
    m0 = metrics()
    threads = [threading.Thread(target=prefill_stream)] + [threading.Thread(target=decode_stream, args=(s,)) for s in range(3)]
    [t.start() for t in threads]
    while any(t.is_alive() for t in threads):
        time.sleep(60)
        m = metrics()
        log(f"soak: {counts} running={m.get('vllm:num_requests_running')} waiting={m.get('vllm:num_requests_waiting')} kv={m.get('vllm:kv_cache_usage_perc', 0) * 100:.1f}%")
    [t.join() for t in threads]
    time.sleep(15)
    m1 = metrics()
    idle = m1.get("vllm:num_requests_running") == 0 and m1.get("vllm:num_requests_waiting") == 0
    record("soak", ok=counts["errors"] == 0 and idle, seconds=SOAK_SECONDS, **counts, idle_after=idle, preemptions=m1.get("vllm:num_preemptions_total", 0) - m0.get("vllm:num_preemptions_total", 0), success_by_reason={k.split("[")[1][:-1]: int(v) for k, v in m1.items() if k.startswith("vllm:request_success_total[")})


PHASES = {
    "smoke": [gate_text, gate_vision, gate_mtp],
    "correctness": [gate_text, gate_determinism, gate_vision, gate_mtp],
    "capabilities": [gate_shared_prefix, gate_mixed_traffic, gate_prefix_churn],
    "retrieval": [gate_retrieval],
    "throughput": [gate_throughput],
    "soak": [gate_soak],
}
PHASES["all"] = PHASES["correctness"] + PHASES["capabilities"] + PHASES["retrieval"] + PHASES["throughput"] + PHASES["soak"]

if __name__ == "__main__":
    phase = sys.argv[1] if len(sys.argv) > 1 else "smoke"
    log(f"phase={phase} model={MODEL} base={BASE} results={RESULTS}")
    for gate in PHASES[phase]:
        try:
            gate()
        except Exception as e:  # a gate crash is a failed gate, not a dead run
            record(gate.__name__.removeprefix("gate_"), ok=False, error=repr(e)[:400])
    log("phase complete")
