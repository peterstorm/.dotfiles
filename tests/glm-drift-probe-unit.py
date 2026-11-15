#!/usr/bin/env python3
"""Unit tests for the GLM drift probe (replay of a Pi session, passkey retrieval).

Run directly (`python3 tests/glm-drift-probe-unit.py`). The pure core (drift metric, session
conversion, request and prompt construction) is tested on plain values; both subcommands are
driven end to end against a fake endpoint on a real socket. No GPU, no engine.
"""
import contextlib
import http.server
import importlib.util
import io
import json
import pathlib
import random
import sys
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts" / "inference" / "shared" / "probe-glm-drift.py"
spec = importlib.util.spec_from_file_location("glm_drift", MODULE)
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe  # dataclasses resolves string annotations through sys.modules
spec.loader.exec_module(probe)

failures = 0


def check(name, condition):
    global failures
    if condition:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}", file=sys.stderr)


# ------------------------------------------------------------------ the drift metric

# Ordinary reasoning prose: varied, English, no repetition.
HEALTHY = (
    "The user wants the switch script to know about a fourth primary. First I should read how the pure decision "
    "treats the container states, because a running container that the switcher does not recognise blocks every "
    "cutover. Then the Pi extension: its tuple of primaries drives the usage string and the completions, so adding "
    "one word there is enough, provided the catalog also carries a model entry for the served id. Next, the tests. "
    "The exhaustive unit test enumerates requests against actives against lasts; a new primary multiplies that by "
    "a fifth in each dimension, which is fine. Finally the contract: the Pi catalog must list exactly the primaries. "
    "Let me also think about rollback: if the new profile fails to start, the previous one must come back, and the "
    "idle gate must have been satisfied before anything was stopped. I think the order is: decide, gate, stop, wait "
    "for free GPUs, start, accept, report. That matches the existing sequencing for the other engine, so nothing new "
    "is needed there. One more consideration is the status output, which should name the served id of whichever "
    "primary is active so that the extension can match it against the catalog. "
) * 1

# What a real spiral looked like (from a Pi session): hyphen-chained words, then Russian, then a few tokens forever.
SPIRAL_START = "Keep comments in the CFG (config comments = their-culture: their-their-ih-ha-their-ih-ih-ha. "
SPIRAL_DRIFT = "их-их-mountPath-их-/conf = их-их-ОБЯЗАТЕЛЬНО их-их-если-crash их-их-tolerable ✓ их-ha-их-ih-их-их-ha. " * 12
SPIRAL_LOOP = "ih-" * 600

healthy = probe.drift_of(HEALTHY * 3)
check("ordinary reasoning is ok", healthy.verdict == "ok")
check("ordinary reasoning has no onset", healthy.onset is None)
check("a healthy window compresses worse than a loop", healthy.worst_ratio is not None and healthy.worst_ratio > probe.LOOP_RATIO + 0.1)

loop = probe.drift_of(HEALTHY * 3 + SPIRAL_LOOP)
check("ih-ih-ih is a loop", loop.verdict == "loop")
check("the loop's onset lands near where it starts", loop.onset is not None and len(HEALTHY * 3) - 2 * probe.WINDOW <= loop.onset <= len(HEALTHY * 3) + probe.WINDOW)
check("the loop's worst ratio is tiny", loop.worst_ratio is not None and loop.worst_ratio < 0.05)

drift = probe.drift_of(HEALTHY * 2 + SPIRAL_START + SPIRAL_DRIFT)
check("foreign-script word salad is drift", drift.verdict in ("drift", "loop"))
check("drift is reported at its first window", drift.onset is not None and drift.onset >= len(HEALTHY * 2) - probe.WINDOW)
check("the non-ASCII share is measured", drift.worst_nonascii is not None and drift.worst_nonascii > probe.DRIFT_SHARE)

check("a text shorter than one window cannot be judged", probe.drift_of("short").verdict == "short")
check("an empty text cannot be judged", probe.drift_of("").verdict == "short")
check("a long but varied text with some non-ASCII (accents, a symbol) is still ok",
      probe.drift_of((HEALTHY + " café déjà vu — naïve ✓ ") * 3).verdict == "ok")

# ------------------------------------------------------- session -> OpenAI conversation

ENTRIES = [
    {"type": "session", "id": "s"},
    {"type": "model_change", "id": "m", "provider": "desktop-vllm", "modelId": "warmind-1017-native"},
    {"type": "message", "id": "u1", "message": {"role": "user", "content": [{"type": "text", "text": "first question"}]}},
    {"type": "message", "id": "a1", "message": {"role": "assistant", "stopReason": "toolUse", "content": [
        {"type": "thinking", "thinking": "old reasoning one"},
        {"type": "text", "text": "let me look"},
        {"type": "toolCall", "id": "call_1", "name": "read", "arguments": {"path": "/x"}}]}},
    {"type": "message", "id": "t1", "message": {"role": "toolResult", "toolCallId": "call_1", "toolName": "read",
                                                 "content": [{"type": "text", "text": "file body"}]}},
    {"type": "message", "id": "a2", "message": {"role": "assistant", "stopReason": "stop", "content": [
        {"type": "thinking", "thinking": "old reasoning two"}, {"type": "text", "text": "answer"}]}},
    {"type": "message", "id": "u2", "message": {"role": "user", "content": "second question"}},
    {"type": "message", "id": "a3", "message": {"role": "assistant", "stopReason": "aborted", "content": [
        {"type": "thinking", "thinking": "ih-ih-ih"}]}},
    {"type": "compaction", "id": "c1", "summary": "SUMMARY OF THE EARLY PART", "firstKeptEntryId": "u2"},
    {"type": "custom_message", "id": "cm", "customType": "cortex-memory", "content": "<!-- memory -->", "display": False},
    {"type": "message", "id": "u3", "message": {"role": "user", "content": [{"type": "text", "text": "third question"}]}},
    {"type": "message", "id": "a4", "message": {"role": "assistant", "stopReason": "toolUse", "content": [
        {"type": "toolCall", "id": "call_2", "name": "bash", "arguments": {"command": "ls"}}]}},
    {"type": "message", "id": "t2", "message": {"role": "toolResult", "toolCallId": "call_2", "toolName": "bash",
                                                 "content": [{"type": "text", "text": "a b c"}]}},
    {"type": "message", "id": "a5", "message": {"role": "assistant", "stopReason": "stop", "content": [
        {"type": "thinking", "thinking": "the target"}]}},
]
TARGET = len(ENTRIES) - 1

before = probe.session_messages(ENTRIES, 6)  # the request that produced a2's successor: everything up to u2, no compaction yet
check("before any compaction the conversation starts at the first message",
      [m["role"] for m in before[1:]] == ["user", "assistant", "tool", "assistant"])
check("a system prompt leads the conversation", before[0]["role"] == "system")
check("an assistant turn replays its reasoning as reasoning_content", before[2]["reasoning_content"] == "old reasoning one")
check("a tool call is rendered with JSON arguments",
      before[2]["tool_calls"] == [{"id": "call_1", "type": "function", "function": {"name": "read", "arguments": json.dumps({"path": "/x"})}}])
check("a tool result answers its call", before[3] == {"role": "tool", "tool_call_id": "call_1", "content": "file body"})
check("an assistant message with no reasoning still carries an empty reasoning_content (Pi's compat flag)",
      before[4]["reasoning_content"] == "old reasoning two" and "tool_calls" not in before[4])

after = probe.session_messages(ENTRIES, TARGET)
roles = [m["role"] for m in after]
check("after a compaction the summary replaces everything before the first kept entry",
      after[1]["role"] == "user" and "SUMMARY OF THE EARLY PART" in after[1]["content"])
check("entries before firstKeptEntryId are dropped", not any("first question" in str(m.get("content")) for m in after))
check("the kept user message follows the summary", "second question" in after[2]["content"])
check("an aborted assistant turn is not replayed", not any("ih-ih-ih" in str(m.get("reasoning_content", "")) for m in after))
check("a custom (context-injection) message is replayed as a user message",
      any(m["role"] == "user" and m["content"] == "<!-- memory -->" for m in after))
check("the target itself is excluded, and everything before it is in order",
      roles[-2:] == ["assistant", "tool"] and not any("the target" in str(m.get("reasoning_content", "")) for m in after))
check("session_messages does not mutate its input", ENTRIES[3]["message"]["content"][2]["arguments"] == {"path": "/x"})

try:
    probe.session_messages(ENTRIES, 999)
    refused = False
except ValueError:
    refused = True
check("a target past the end of the session raises", refused)

# ----------------------------------------------------------- requests per condition

messages = [{"role": "user", "content": "q"}]
base = probe.replay_payload("m", messages, "baseline", seed=3, max_tokens=500)
check("baseline is what Pi sends: max effort, no template kwargs, no budget",
      base["reasoning_effort"] == "max" and "chat_template_kwargs" not in base and "thinking_token_budget" not in base)
check("every request is reproducible by seed", base["seed"] == 3 and base["max_tokens"] == 500 and base["stream"] is False)
clear = probe.replay_payload("m", messages, "clear", seed=1, max_tokens=500)
check("clear adds clear_thinking only", clear["chat_template_kwargs"] == {"clear_thinking": True} and "thinking_token_budget" not in clear)
cap = probe.replay_payload("m", messages, "clear+cap", seed=1, max_tokens=500)
check("clear+cap adds a reasoning budget as well", cap["chat_template_kwargs"] == {"clear_thinking": True} and cap["thinking_token_budget"] == probe.CAP_TOKENS)
try:
    probe.replay_payload("m", messages, "nope", seed=1, max_tokens=500)
    unknown = False
except ValueError:
    unknown = True
check("an unknown condition raises", unknown)
check("the messages are carried unchanged", clear["messages"] == messages and clear["messages"] is not messages)
sys_messages = [{"role": "system", "content": "s"}, {"role": "user", "content": "q"}]
padded = probe.replay_payload("m", sys_messages, "clear+pad", seed=1, max_tokens=500, pad="IRRELEVANT FILLER")
check("clear+pad clears the reasoning like clear", padded["chat_template_kwargs"] == {"clear_thinking": True})
check("clear+pad puts the filler right after the system prompt, before the conversation",
      [m["role"] for m in padded["messages"]] == ["system", "user", "user"] and "IRRELEVANT FILLER" in padded["messages"][1]["content"]
      and padded["messages"][2]["content"] == "q")
check("the padding says it is irrelevant, so it cannot become part of the task", "not relevant" in padded["messages"][1]["content"].lower())
try:
    probe.replay_payload("m", sys_messages, "clear+pad", seed=1, max_tokens=500)
    no_pad = False
except ValueError:
    no_pad = True
check("clear+pad without filler raises rather than silently running unpadded", no_pad)
check("other conditions ignore a supplied pad", "IRRELEVANT" not in json.dumps(probe.replay_payload("m", sys_messages, "clear", seed=1, max_tokens=500, pad="IRRELEVANT")))
check("seeds can start anywhere", probe.seeds(3, start=9) == [9, 10, 11] and probe.seeds(2) == [1, 2])

# ------------------------------------------------------------------------ passkey

rng = random.Random(7)
filler = "\n\n".join(f"Paragraph {i}: " + "alpha beta gamma delta " * 12 for i in range(400))
key = probe.make_key(rng)
check("a passkey is eight unambiguous characters", len(key) == 8 and key.isalnum() and not set(key) & set("0O1lI"))
check("two draws differ", probe.make_key(rng) != key)
for depth in (0.1, 0.5, 0.9):
    prompt = probe.passkey_prompt(filler, key, depth)
    at = prompt.index(key) / len(prompt)
    check(f"the needle sits near depth {depth}", abs(at - depth) < 0.03)
    check(f"the passkey appears once at depth {depth} (the question never repeats it)", prompt.count(key) == 1)
check("the question comes last", probe.passkey_prompt(filler, key, 0.5).rstrip().endswith("Reply with only the passkey."))
check("the filler is not damaged around the needle", probe.passkey_prompt(filler, key, 0.5).count("Paragraph 399") == 1)
check("an answer holding the key is found", probe.passkey_found(f"The passkey is {key}.", key))
check("a wrong key is not found", not probe.passkey_found("The passkey is ABCDEFGH.", key))
check("an empty answer is not found", not probe.passkey_found("", key))
check("a near miss (one character off) is not found", not probe.passkey_found(key[:-1] + ("A" if key[-1] != "A" else "B"), key))

# -------------------------------------------------- end to end (fake endpoint)

GOOD_THINKING = HEALTHY * 6
BAD_THINKING = HEALTHY * 2 + SPIRAL_START + SPIRAL_DRIFT + SPIRAL_LOOP


class Fake(http.server.BaseHTTPRequestHandler):
    seen = []

    def log_message(self, *arguments):
        pass

    def _send(self, body):
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        self._send({"data": [{"id": "fake-glm"}]})

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        Fake.seen.append(request)
        text = request["messages"][-1]["content"]
        kwargs = request.get("chat_template_kwargs") or {}
        # Replay: baseline spirals on odd seeds, a cleared prompt never does.
        spirals = request.get("seed", 0) % 2 == 1 and not kwargs.get("clear_thinking")
        if "passkey" in text:
            # Retrieval: the model finds the key unless the prompt is longer than 100,000 characters.
            found = len(text) <= 100_000
            keyword = text.split("passkey for the vault is ")[1].split(".")[0] if "passkey for the vault is" in text else "?"
            message = {"content": f"{keyword}" if found else "I cannot find it.", "reasoning_content": ""}
        else:
            message = {"content": "done", "reasoning_content": BAD_THINKING if spirals else GOOD_THINKING}
        self._send({"choices": [{"message": message, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": max(1, len(text) // 4), "completion_tokens": 100}})


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}"


def run_main(arguments):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = probe.main(arguments)
    return code, out.getvalue(), err.getvalue()


with tempfile.TemporaryDirectory() as scratch:
    scratch = pathlib.Path(scratch)
    session = scratch / "session.jsonl"
    session.write_text("".join(json.dumps(entry) + "\n" for entry in ENTRIES))
    common = ["--url", url, "--key-file", str(scratch / "none"), "--concurrency", "2"]

    out_dir = scratch / "replay"
    code, out, err = run_main(["replay", *common, "--session", str(session), "--target", str(TARGET),
                               "--conditions", "baseline,clear", "--samples", "4", "--out", str(out_dir)])
    receipt = json.loads((out_dir / "receipt.json").read_text()) if (out_dir / "receipt.json").exists() else {}
    check("replay exits 0", code == 0)
    check("replay discovers the served model", receipt.get("model") == "fake-glm")
    rows = {row["condition"]: row for row in receipt.get("summary", [])}
    check("replay ran every sample of every condition", receipt.get("runs") is not None and len(receipt["runs"]) == 8)
    check("the baseline's odd seeds spiral", rows.get("baseline", {}).get("degenerate") == 2)
    check("the cleared prompt does not", rows.get("clear", {}).get("degenerate") == 0)
    check("the table names the conditions and counts", "baseline" in out and "clear" in out and "2/4" in out)
    check("each run keeps its thinking for inspection", len(list((out_dir / "runs").glob("*.json"))) == 8)
    check("the replayed request carried the session's messages",
          any(r["messages"][1]["content"].count("SUMMARY") for r in Fake.seen if "messages" in r and len(r["messages"]) > 2))

    hay_replay = scratch / "hay-replay"
    hay_replay.mkdir()
    for number in range(30):
        (hay_replay / f"n{number}.md").write_text(f"Note {number}. " + ("filler words about topic %d. " % number) * 150)
    pad_dir = scratch / "replay-pad"
    code, out, err = run_main(["replay", *common, "--session", str(session), "--target", str(TARGET), "--conditions", "clear+pad",
                               "--samples", "2", "--seed-start", "5", "--haystack", str(hay_replay), "--pad-chars", "20000", "--out", str(pad_dir)])
    check("a padded replay exits 0", code == 0)
    padded_runs = json.loads((pad_dir / "receipt.json").read_text())["runs"] if (pad_dir / "receipt.json").exists() else []
    check("a padded replay uses the requested seeds", sorted(run["seed"] for run in padded_runs) == [5, 6])
    check("the padded request carries the requested amount of filler",
          any(len(r["messages"][1]["content"]) >= 15000 and "not relevant" in r["messages"][1]["content"].lower()
              for r in Fake.seen if "messages" in r and len(r["messages"]) > 2))
    code, out, err = run_main(["replay", *common, "--session", str(session), "--target", str(TARGET), "--conditions", "clear+pad",
                               "--samples", "1", "--out", str(scratch / "nopad")])
    check("clear+pad with no --pad-chars is refused up front", code == 2 and "pad" in err)

    code, out, err = run_main(["replay", *common, "--session", str(scratch / "absent.jsonl"), "--target", "3",
                               "--out", str(scratch / "x")])
    check("a missing session is refused with its reason", code == 2 and "error" in err)
    code, out, err = run_main(["replay", *common, "--session", str(session), "--target", "999", "--out", str(scratch / "y")])
    check("a target outside the session is refused", code == 2 and "target" in err)

    Fake.seen.clear()
    hay = scratch / "hay"
    hay.mkdir()
    for number in range(40):
        (hay / f"note{number}.md").write_text(f"Note {number}. " + ("some varied filler text about topic %d. " % number) * 200)
    pass_dir = scratch / "passkey"
    code, out, err = run_main(["passkey", *common, "--contexts", "4000,60000", "--depths", "0.2,0.8", "--trials", "2",
                               "--haystack", str(hay), "--out", str(pass_dir), "--chars-per-token", "4"])
    check("passkey exits 0", code == 0)
    pr = json.loads((pass_dir / "receipt.json").read_text()) if (pass_dir / "receipt.json").exists() else {}
    cells = {(c["context"], c["depth"]): c for c in pr.get("cells", [])}
    check("passkey ran every cell and trial", len(pr.get("runs", [])) == 8)
    check("the short context is retrieved at every depth", all(cells.get((4000, d), {}).get("found") == 2 for d in (0.2, 0.8)))
    check("the long context fails at every depth", all(cells.get((60000, d), {}).get("found") == 0 for d in (0.2, 0.8)))
    check("the table shows the pattern", "4000" in out and "60000" in out)
server.shutdown()

if failures:
    print(f"\n{failures} failure(s)", file=sys.stderr)
    sys.exit(1)
print("\nall glm-drift-probe tests passed")
