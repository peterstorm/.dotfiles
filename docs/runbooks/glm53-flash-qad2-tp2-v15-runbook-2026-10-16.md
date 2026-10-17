# GLM-5.3 Flash qad2 TP2 v15 runbook — 2026-10-16

## Status

**Serving since 2026-10-16 23:03 UTC** (accepted on the first swap; replaces
v14). Chain: preflight → idle gate → v14 quiesced → CUDA runtime probe
(cuBLAS + cuDNN + two-GPU NCCL on driver 595.91.07) → launch →
`HEALTHY + AUTHENTICATED + EXACT MODEL` → boot receipt → `restart=unless-stopped`.
Boot ~5 min on a cold kernel cache. Boot evidence: `Using max model len
1048576`, `GPU KV cache size: 1,844,162 tokens, Maximum concurrency for
1,048,576 tokens per request: 1.76x` — exactly the recipe. Smokes: exact-string
text completion (42 reasoning tokens at server-default high), per-request
`reasoning_effort: low` override honoured, `get_weather` tool call parsed by
glm47 (`finish_reason: tool_calls`), image request answered correctly, Pi
end-to-end (`pi -p --model desktop-vllm/glm-5.3-flash-qad2-tp2-v15:low`).
VRAM ~95.3 GB used per card. Reclaw repinned to
`glm-5.3-flash-qad2-tp2-v15:low` (homelab rebuilt, service active).

## Immutable identities

- Image: `ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2`,
  pulled **by digest** (beta tags move)
  `sha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178`
  (vLLM v0.1.dev21832+g54e054785 lab build, torch 2.14.0a0, CUDA 13.4)
- Image id: `sha256:02c46866e4358592f43083980b35f73fbd08c723813b92f8205ab6446bc2b45d`
  (recorded as `IMAGE_CONFIG` in the run and download scripts; 30.6 GB)
- Checkpoint: `local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD` @
  `0a0417631b4065d16e9639f327f44a0a4237a537` (branch `qad2-kda-w8a16-csf`,
  ~177 GB, a full download — not a delta on v14's Spark checkpoint), in
  `/models/hf-cache/glm53-flash-qad2-tp2-v15`, mounted read-only, served
  offline (`HF_HUB_OFFLINE=1`)
- Launcher: `lil-serve --profile glm53-flash --hardware rtx-pro-6000-pcie
  --preset glm53-tp2 -- --cache-mode vram`
- Served model: `glm-5.3-flash-qad2-tp2-v15` (repository id; overrides the
  preset's name through `SERVED_MODEL_NAME`)
- Recipe (vendored): `recipe-glm-5.3-flash-vllm.md` in
  `docs/research/glm53-qad2-tp2-v15-2026-10-16-evidence/`

## Why this profile

The recipe reports (2026-10-13…15, two cards at 300 W) the qad2 checkpoint on
this lab build as a production replacement for SGLang v0.6.1: 1,844,162 KV
tokens in VRAM with a 1M context on the same two PCIe cards, cold prefill
~7.9K tok/s at 8–32K and ~6.5K tok/s at ~498K, decode 172.5 tok/s C1 /
290.7 tok/s C4, GSM8K parity with SGLang (1,250 vs 1,255, p=0.55), tool-call
template, vision stress and OpenAI contract passes. v14 (Spark checkpoint,
`glm53-spark-tp2`) had a 986,295-token KV pool and four slots.

## Final configuration (proven by `--print-config`)

- TP2 / DCP2, MTP3 (probabilistic draft, BF16 draft head)
- preset `glm53-tp2`, hardware `rtx-pro-6000-pcie`, load format `nvfp4_csf`
- fixed FP8 KV: 7,650,410,496 bytes per GPU (7296 MiB)
- `max-model-len: -1` — memory-resolved (recipe: 1,048,576). **Do not pin a
  shorter context**: `--max-model-len 524288` regroups the hybrid KV cache and
  the pool falls from 1,844,162 to 1,561,213 tokens on the same memory. Cap
  context in the client instead (`pi/models.json`: 524,288).
- eight request slots; 4096-token prefill budget; A4 expert prefill;
  `VLLM_GLM53_KDA_MXFP8_ACTIVATION_MODE=prefill`
- `CACHE_MODE=vram` — GPU-only, no host-RAM KV tier (v14's LMCache option is
  not part of v15; the run script rejects any other `CACHE_MODE`)
- server-default `DEFAULT_CHAT_TEMPLATE_KWARGS={"reasoning_effort":"high","clear_thinking":false}`
  instead of the preset's max; vLLM honours a per-request
  `chat_template_kwargs.reasoning_effort`, so Pi's `:max` still reaches max
- tool parser `glm47`, reasoning parser `glm45`; checkpoint generation
  defaults temperature 1.0 / top_p 0.95
- cache host dir `/models/vllm-cache/glm53-flash-qad2-tp2-v15` → `/cache`
  (keep it: a new image retunes kernels on first boot; the cache keeps
  restarts at ~4–5 min instead of ~8–9)

## Build and static verification

```bash
bash tests/glm53-flash-qad2-tp2-v15-contract.sh
bash scripts/inference/glm53/pull-glm53-flash-qad2-tp2-v15-image.sh
bash scripts/inference/glm53/download-glm53-flash-qad2-tp2-v15-checkpoint.sh --wait
```

The pull script (CPU-only) runs the exact launcher argv with
`--print-config` and asserts 23 recipe facts (revision `0a041763…`, KV bytes,
effort high, slots, prefill, parallelism, cache mode, …) plus the
`SERVED_MODEL_NAME` override, then writes
`~/.local/state/glm53/flash-qad2-tp2-v15-image.identity`. The download is
resumable (`--restart on-failure:5`) and writes `.download-complete` after a
local-only snapshot proof; `--verify` re-checks and writes the receipt.

Disk note (2026-10-16): rpool had 118 GB free. To fit the checkpoint the
Qwen3.8 Flash Next images/containers and the v14 Spark checkpoint
(`/models/hf-cache/glm53-flash-spark-tp2-v14`, 175 GB) were deleted. **v14 is
therefore not an instant rollback** — re-run its download script first.

## Preflight

```bash
bash scripts/inference/glm53/run-glm53-flash-qad2-tp2-v15.sh --preflight
```

Static-only: image id + digest binding, CPU-only launch-plan proof with the
launch argv, offline checkpoint marker/snapshot. `--launch` adds the machine
gates (two RTX PRO 6000 Blackwell ≥ 96 GB, memory idle, power limit equal to
`gpuPowerLimitWatts` in `machines/desktop/default.nix`, comfyui stopped, port
8000 free) and the CUDA runtime probe (cuBLAS + cuDNN + two-GPU NCCL
allreduce). The desktop driver is 595.91.07 while the image is built against
615.65.02; v14's identical CUDA 13.4 runtime passed the same probe on this
driver.

The recipe runs at 300 W per card; the desktop keeps its declarative
`gpuPowerLimitWatts` pin, which the run script enforces.

## Transactional swap (start)

```bash
bash scripts/inference/glm53/switch-glm53-qad2-tp2-v15.sh status
bash scripts/inference/glm53/switch-glm53-qad2-tp2-v15.sh start
```

Idle gate (three samples, zero running/waiting) → stop the previous profile →
launch v15 at `--restart no` → accept only on `/health` **and** an
authenticated `/v1/models` listing exactly `glm-5.3-flash-qad2-tp2-v15` →
boot receipt `~/.local/state/glm53/flash-qad2-tp2-v15-boot-receipt.txt` →
promote `restart=unless-stopped`. On failure the previous profile set is
restarted (v14 will not come back without its checkpoint) and the failed
container is quiesced. The container sets `--stop-timeout 180` (recipe: let
CUDA tear down on both cards); the shared switch helpers still stop with
`-t 30`.

## First-boot acceptance gate

1. `docker logs -f glm53-flash-qad2-tp2-v15` — expect `GPU KV cache size:
   1,844,162 tokens` and a 1,048,576 max model len.
2. Smoke: one text completion, one image request, one tool call through
   `pi --model desktop-vllm/glm-5.3-flash-qad2-tp2-v15`.
3. Give reasoning room: thinking shares `max_tokens`; a small budget can
   return an empty answer.
4. Measure recall at temperature 1 (the checkpoint default), not temp 0.

## Rollback

```bash
bash scripts/inference/glm53/switch-glm53-qad2-tp2-v15.sh stop
bash scripts/inference/glm53/download-glm53-flash-spark-tp2-v14-checkpoint.sh --wait  # v14 checkpoint was deleted
bash scripts/inference/glm53/switch-glm53-spark-tp2-v14.sh start
```

## Notes and deviations from the recipe

- Port 8000 on the host network (repository convention; `desktop-vllm` points
  there) instead of the recipe's published 8001.
- `docker run` with `--restart no` + switcher promotion instead of compose
  with `restart: unless-stopped`.
- GPUs selected by index via `GPU_ORDER` (0,1) instead of `NVIDIA_VISIBLE_DEVICES`
  UUIDs; the run script requires exactly two RTX PRO 6000 Blackwell cards.
- `--security-opt seccomp=unconfined`, the API key through `--env-file`, and
  the repository's served model id, as for every desktop profile.
