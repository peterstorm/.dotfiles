# Qwen3.8-27B BF16 + DFlash2 — candidate vLLM image speed trial (2026-10-02)

Throw-away trial recipe, **not** a pinned profile: no launcher script, no
contract test, no switcher entry. Goal is only "how fast can 27B BF16 + DFlash2
go on a newer vLLM than the v3 pin?". Research behind it: the 2026-10-02
upstream review in this session (v3 pin `nightly-a9a17e7` is 2,040 commits and
three releases behind).

Everything about the model stays identical to v3 (same target, same draft,
BF16 weights/KV, FP32 GDN state, TP1, DFlash2 depth 7). **Only the image
changes.** Prefix caching is ON (tested, see below).

## Prefix caching: tested, works on candidate B

Upstream issue vllm-project/vllm#58894 reports that on v0.30.0 DFlash2 on a
hybrid-GDN target can collapse to 0 % acceptance (or hit an illegal memory
access) on the first prefix-cache hit; root cause is the mamba state-index seed
fixed by PR #55601, which is still open. Because of that this recipe was first
run with caching off, then re-run with `--enable-prefix-caching` and tested on
nightly `0cbac6c` (2026-10-02, GPU1, BF16 KV, `--kv-cache-dtype auto`):

- 54k-token prompt: cold 15.7 s -> repeat 1.7 s; 52,416/53,900 tokens hit (97 %).
- 13k-token prefix (the reporter's size): cold, hit, then a 20k extension of it
  (partial hit, 23,296 tokens) all clean.
- Acceptance length stays healthy after hits (code 5.98, prose 3.8-5.0, 4
  concurrent hits on a 54k prefix 2.63 on creative writing at temp 0); no 0 %
  collapse, no crash, no Xid, container stable.
- Engine log: "Mamba cache mode is set to align", attention block 832 (the
  reporter's failing config had the draft block lowered to 64 with FP8 KV on
  Ada/Orin; we do not hit that).

So caching is **on** in the recipe. Still watch #55601, #58894, #53477 (context
reprocessed every reply) and #54928 (greedy output drift); if acceptance ever
pins near 0 after a hit, relaunch with `--no-enable-prefix-caching`.

## Candidates

| | Image | Digest (multi-platform) | Has |
|---|---|---|---|
| **B (try first)** | `vllm/vllm-openai:nightly-0cbac6cd1305f710e12193596b27488397bcb205` | `sha256:8e6e3752946ff2dde451b313cbaec2ea8e7b52221b21bfbcf53fb68dd4f4c42e` | everything in A **plus** fused DFlash2 grouped conv (#55960), draft CUDA-graph context K/V precompute (#57632), async scheduling for DFlash (#58065), GDN spec-decode perf (#58762/#58763) |
| **A (fallback)** | `vllm/vllm-openai:v0.30.0` (CUDA 13.0) | `sha256:8a69ffad015f138d7170c4ddc429e230a3bc1c1719f67e14324749df200a4b90` (amd64 `sha256:5f5e5352…6d40`) | FlashInfer GDN prefill on SM12x (#55715), DFlash RoPE/AOT-schedule/MRV2 fixes (#54373, #54374, #54826, #56181) |

Neither contains #59735 (non-speculative GDN decode, 2 Oct). Run **B first**; if
it crashes, wedges, or acceptance looks wrong, repeat the whole recipe with A
before concluding anything. Driver 595.91 is fine for CUDA 13.0 images (the
Karmic Kraken *beta* builds need driver 615+ — not used here).

## Preconditions (graphical specialisation)

- Run on **physical GPU1** (`03:00.0`). In the graphical spec GPU0 hosts X,
  Firefox, and Steam; v3 is pinned to GPU0 only because ComfyUI owns GPU1, and
  ComfyUI is inactive right now.
- `docker ps` shows nothing on port 8000; `systemctl is-active comfyui` is
  `inactive`; GPU1 memory ≈ 15 MiB.
- GPU power cap ≤ 450 W (it is 400 W via NixOS).
- ~35 GB free in `/var/lib/docker` (135 GB free); weights are on `/models`
  (`/models/Qwen3.8-27B`) and `~/Desktop/Qwen3.8-27B-DFlash2` (rev `dedf8df`).
- Fans: GPU util > 15 % flips the fan daemon to the load curve — expected.

```bash
nvidia-smi --query-gpu=index,memory.used,power.limit --format=csv
docker ps; systemctl is-active comfyui; ss -ltn 'sport = :8000'
```

## 1. Pull by digest and probe the image

```bash
IMG=vllm/vllm-openai
DIGEST=sha256:8e6e3752946ff2dde451b313cbaec2ea8e7b52221b21bfbcf53fb68dd4f4c42e   # B
docker pull "$IMG@$DIGEST"

# Same source assertions v3 uses — rejects images where DFlash2 cannot load
# (the 08-22/08-24 #52560 regression).
docker run --rm --entrypoint python3 "$IMG@$DIGEST" -c '
import inspect
from vllm.model_executor.models.qwen3_dflash import DFlashQwen3Model
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.worker.gpu.spec_decode.dflash2.speculator import DFlash2Speculator
s = ModelRegistry.get_supported_archs(); src = inspect.getsource(DFlashQwen3Model)
assert "Qwen3_5ForConditionalGeneration" in s and "DFlash2DraftModel" in s
assert "decoder_layer_cls = DFlashQwen3DecoderLayer" in src
assert "self.decoder_layer_cls(" in src and DFlash2Speculator
print("ok")'
docker image inspect --format '{{index .Config.Labels "ai.vllm.build.commit"}}' "$IMG@$DIGEST"
```

If the import probe fails (module paths moved in newer nightlies), that is a
finding, not a bug in this recipe — note the error and try A.

## 2. Launch (GPU1, trial container, no restart policy)

```bash
NAME=qwen38-27b-trial
CACHE=/models/vllm-cache/qwen38-trial          # fresh compile/JIT cache
mkdir -p "$CACHE"
docker rm -f "$NAME" 2>/dev/null || true

docker run -d --init \
  --name "$NAME" \
  --gpus "device=1" \
  --ipc=host --network host \
  --ulimit memlock=-1 --ulimit nofile=1048576 --ulimit stack=67108864 \
  --env-file ~/.config/qwen38/vllm-dflash2-tp1-bf16kv-v3.env \
  -v /models/Qwen3.8-27B:/models/Qwen/Qwen3.8-27B:ro \
  -v ~/Desktop/Qwen3.8-27B-DFlash2:/models/incoai/Qwen3.8-27B-DFlash2:ro \
  -v "$CACHE":/root/.cache \
  -e CUDA_VISIBLE_DEVICES=0 -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMG@$DIGEST" \
  /models/Qwen/Qwen3.8-27B \
  --served-model-name qwen3.8-27b \
  --dtype bfloat16 \
  --tensor-parallel-size 1 \
  --max-model-len 262144 \
  --max-num-seqs 8 \
  --max-num-batched-tokens 4096 \
  --gpu-memory-utilization 0.92 \
  --kv-cache-dtype auto \
  --mamba-ssm-cache-dtype float32 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --speculative-config '{"method":"dflash","model":"/models/incoai/Qwen3.8-27B-DFlash2","num_speculative_tokens":7}' \
  --attention-backend flashinfer \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 --port 8000

docker logs -f "$NAME"      # first boot compiles/JITs for several minutes
```

Differences from v3: `--gpus device=1`, new image,
fresh cache dir, no `--restart` policy. The env file only carries
`VLLM_API_KEY` (same key as always, `~/.config/qwen38/api-key`).

## 3. Verify it is actually the intended stack

```bash
docker logs "$NAME" 2>&1 | grep -E "Qwen3_5ForConditionalGeneration|DFlash2DraftModel|DFlash2Qwen3ForCausalLM|FLASHINFER|GDN|async|prefix" | head -20
curl -fsS http://127.0.0.1:8000/health
curl -fsS -H "Authorization: Bearer $(cat ~/.config/qwen38/api-key)" http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
```

Expect: target arch `Qwen3_5ForConditionalGeneration`, draft arch
`DFlash2DraftModel`, FlashInfer backend, prefix caching enabled (log: `Mamba cache mode is set to 'align'`). A "no KV
cache group could be identified" warning is cosmetic upstream (#58894 thread);
a CUDA illegal-memory-access / Xid in `journalctl -k` is not.

## 4. Measure

```bash
# C1 short, C8 short, C4 ~22K-token prefill; prints tok/s, TTFT, ITL, accept counters
BACKEND=vllm-b-nightly-0cbac6c bash ~/.dotfiles/scripts/inference/shared/probe-inference-throughput.sh

# Live acceptance (gauge; healthy ≈ 3.0–5.7, ~1.0 means broken)
curl -fsS http://127.0.0.1:8000/metrics | grep -E 'spec_accept_length|spec_decode_num_(drafts|accepted)'
```

Record: C1/C8 aggregate tok/s, C4-long TTFT, acceptance length, GPU1 temp and
power. For context only: DSpark TP2 measured ~143 tok/s end-to-end on
2026-08-16; no stored v3 TP1 baseline exists in `benchmarks/`. Optionally run
the same probe against v3 later for a true delta — not needed for this trial.

## 5. Knobs (one at a time, restart between)

1. **Async scheduling** — if output stalls or acceptance is odd on B, add
   `--no-async-scheduling` (new default path from #58065).
2. `num_speculative_tokens` 7 → 5 (cheaper verify, lower accept length) or keep 7.
3. `--max-num-batched-tokens` 4096 → 8192 (faster long prefill, more memory).
4. `--gpu-memory-utilization` 0.92 → 0.95 (GPU1 has no desktop load).
5. Drop `--attention-backend flashinfer` only as a diagnosis step (v3 forces it).

## 6. Stop / roll back

```bash
docker rm -f qwen38-27b-trial        # frees GPU1 and port 8000
```

v3 remains the supported profile and is unchanged. Re-launching it needs GPU0,
which in graphical mode is the display GPU (X + Steam use ~1.4 GB; the script's
guard allows 2048 MiB) — or reboot into the headless entry. Nothing in this
trial writes repo state; `/models/vllm-cache/qwen38-trial` can be deleted.

## Failure signatures

| Symptom | Likely cause | Action |
|---|---|---|
| Boot: `DFlash2DraftModel` unloadable / `decoder_layer_cls` | nightly lacks #53435 | use A or a different nightly |
| Acceptance ≈ 0 % or ~1.0 right after start | wiring/regression | check logs, retry on A |
| IMA / Xid 31 / `Xid 79` | kernel or PCIe issue | stop; check `journalctl -k`; Xid 79 history is on GPU0 |
| Engine alive, `/health` 200, no tokens | wedge (cf. #58422 on SM120) | `docker rm -f`, retry with `--no-async-scheduling` |
| OOM at boot | KV for 262144 ctx at 0.92 | lower `--max-model-len` or utilisation |

## Watch list before pinning a new image

- vllm-project/vllm#55601 (mamba prefix-hit seed) — not hit in our test, but unmerged; re-test after any image change.
- #58894, #53477, #54928 — DFlash2 prefix-cache/context bugs.
- #59735 — non-speculative GDN decode perf (not in either candidate).
- RedHatAI/Qwen3.8-27B-speculator.dspark (2026-09-21) — DSpark draft worth a
  future A/B against DFlash2 once an image is chosen.

If a candidate beats v3 and is stable, promote it the normal way: new pinned
launcher + runbook + `tests/*-contract.sh`, never by editing v3 in place.
