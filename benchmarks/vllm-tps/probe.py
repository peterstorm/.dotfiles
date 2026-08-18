#!/usr/bin/env python3
"""Non-scientific vLLM TPS probe for the desktop box.

Streams one chat completion against the OpenAI-compatible endpoint, times
time-to-first-token and steady-state decode rate, and reports vLLM's own
usage counts. Thinking is toggled via the Qwen3.8 chat-template kwargs
(`enable_thinking` / `reasoning_effort`); thinking tokens stream in the
`reasoning` delta field, answer tokens in `content`.

Usage:
  probe.py --thinking off
  probe.py --thinking xhigh --max-tokens 1500

Requires: python3 stdlib only. The API key is resolved the same way the
pi `desktop-vllm` provider does (local key file, else ssh to the desktop).
"""
import argparse
import json
import os
import subprocess
import time
import urllib.request

BASE = os.environ.get("VLLM_BASE_URL", "http://192.168.0.80:8000/v1")
MODEL = os.environ.get("VLLM_PROBE_MODEL", "qwen3.8-27b")

KEY_PATHS = [
    "~/.config/ds4-flash/api-key",
    "~/.config/qwen38/api-key",
    "~/.config/muse-glimmer/api-key",
    "~/.config/sops-nix/secrets/vllm-api-key",
]

PROMPT = (
    "Explain in detail how a hash map works internally: the hashing "
    "function, bucket array, chaining vs open addressing, load factor, "
    "rehashing, and collision handling. Be thorough and technical. "
    "No bullet points, just prose paragraphs."
)


def resolve_key() -> str:
    for raw in KEY_PATHS:
        path = os.path.expanduser(raw)
        if os.path.isfile(path):
            return open(path).read().strip()
    return subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "desktop",
         "cat ~/.config/ds4-flash/api-key || cat ~/.config/qwen38/api-key "
         "|| cat ~/.config/muse-glimmer/api-key"],
        capture_output=True, text=True,
    ).stdout.strip()


def run(key: str, thinking: bool, effort: str | None, max_tokens: int) -> None:
    kwargs = {"enable_thinking": thinking, "preserve_thinking": True}
    if thinking and effort:
        kwargs["reasoning_effort"] = effort
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": kwargs,
    }
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {key or 'x'}"},
    )
    t0 = time.monotonic()
    ttft = None          # first answer (content) token
    first_reasoning = None
    usage = None
    with urllib.request.urlopen(req) as resp:
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if payload == "[DONE]":
                break
            try:
                chunk = json.loads(payload)
            except json.JSONDecodeError:
                continue
            if chunk.get("usage"):
                usage = chunk["usage"]
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {})
                if delta.get("reasoning_content") or delta.get("reasoning"):
                    first_reasoning = (first_reasoning
                                        if first_reasoning is not None
                                        else time.monotonic() - t0)
                if delta.get("content") and ttft is None:
                    ttft = time.monotonic() - t0
    total = time.monotonic() - t0
    out = (usage or {}).get("completion_tokens", 0)
    prompt = (usage or {}).get("prompt_tokens", 0)
    print(f"prompt_tokens={prompt} completion_tokens={out}")
    print(f"TTFT(first answer token)={ttft:.2f}s  total={total:.2f}s"
          + (f"  first_reasoning={first_reasoning:.2f}s" if first_reasoning else ""))
    if ttft and out > 1:
        decode = (out - 1) / max(total - ttft, 1e-6)
        overall = out / max(total, 1e-6)
        print(f"DECODE TPS={decode:.1f}  overall(incl TTFT)={overall:.1f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thinking", choices=["off", "low", "xhigh"],
                        default="off")
    parser.add_argument("--max-tokens", type=int, default=512)
    args = parser.parse_args()
    key = resolve_key()
    if not key:
        raise SystemExit("no API key found")
    run(key, args.thinking != "off", None if args.thinking == "off" else args.thinking,
        args.max_tokens)


if __name__ == "__main__":
    main()
