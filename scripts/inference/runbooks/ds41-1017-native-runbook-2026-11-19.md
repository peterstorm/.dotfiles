# ds41-1017-native runbook — DeepSeek-V4.1-Flash-1017 and WARMIND-1017 on ds4-native (2026-11-19)

Native-precision serving of DeepSeek-V4.1-Flash-1017 (and jcartu's abliterated WARMIND-1017
derivative) on the desktop's two RTX PRO 6000 Blackwell GPUs. This is one of the four primaries;
switching is `switch-primary.sh warmind|deepseek`
([switch-primary runbook](switch-primary-runbook-2026-11-19.md)).

Status line: engine `DS4N_COMMIT=d3274aa` (ds4-native main), Maya server `b3fa99ec` + keepalive
patch, image `ds4-native-dev:2`, WARMIND v1.1 "orth4c" `@a6382f22` default / v1.0 `@4fbce630`
rollback / DeepSeek `@1bae0e10`. The contract for these pins is the launcher itself plus
`tests/switch-primary-unit.sh`; the engine's own tests run at `--install`.

## What runs

Two processes, one container (`ds41-1017-native`, network host, port 8000):

- **Maya's server** (`serve/server.py`, MIT, at the pinned commit with
  `maya-serve-keepalive.patch`) — OpenAI-compatible API: chat template, tokenization, tool-call
  parsing, streaming, `--fit-max-tokens`.
- **`ds4n-serve`** (the engine, built from the pinned commit into
  `/models/ds41/native/bin/ds4n-serve-<commit>`) — speaks GEN/T/DONE on stdio to Maya. The engine
  owns both GPUs under 2-way tensor parallelism: routed experts stream from the NVMe Expert store
  into a VRAM slot cache (victim tier in host RAM), attention is Exact on the released FP8/MXFP4
  bytes, DSpark drafts with adaptive verification (drafts are verified, so the draft head changes
  speed only, never output).

Served names: `warmind-1017-native` (WEIGHTS=warmind | warmind-v1.0) or
`deepseek-v4.1-flash-native` (WEIGHTS=deepseek). Maya answers any model id with what is loaded;
the container label `ai.peterstorm.inference.served-model` is what the switcher reads.

## Files (all under `/models/ds41`)

| path | what | notes |
|---|---|---|
| `native/experts.ds4n` | the Expert store: all 15,360 routed experts, 18 MiB records, 289 GB | converted and verified from the merged GGUF (`build_store.sh` receipt in `native/`) |
| `native/backbone.safetensors` | DeepSeek's dense/attention/backbone weights, 9.4 GB FP8 | `WEIGHTS=deepseek` |
| `native/warmind-v1.1/backbone.safetensors` | WARMIND v1.1 Backbone (132 tensors re-written: `attn.wo_b` + `ffn.shared_experts.w2`, layers 4–36) | default; `warmind/` = v1.0 rollback. Both carry `__metadata__.source` = the derivative's repo@rev, checked at launch |
| `engram/DeepSeek-V4.1-Flash-1017-MXFP4.gguf` | the merged antirez GGUF, 467 GiB | **runtime-required, every launch** (`--gguf`): it holds the Engram tables that stream per token. NOT redundant with the store — do not archive it while this profile exists. The dataset is tuned: recordsize 16K, compression off, primarycache=all |
| `hf-1017-mtp/` | DeepSeek's released MTP shards (the DSpark head: `model-00044/45/46-of-00048`) + tokenizer | DSpark input; drafts are verified so any head in this layout only changes speed |
| `baseline/maya-expert-profile.bin` | the expert-profile prior for the RAM tier | built from real Maya traffic (`tools/expert-profile`) |
| `native/serve/` | rewritten-at-launch `ds4-native.json` config, tokenizer export, engine log | the config is generated, hand-edits are lost |
| `native/bin/` | `ds4n-serve-<commit>` + `.commit` stamp | produced by `--install` |

## Operating

```bash
# from any machine (re-runs itself on desktop over ssh):
~/.dotfiles/scripts/inference/switch-primary.sh warmind          # preferred entry
# directly on desktop:
scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh --preflight   # gates only
scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh --install     # build engine + server at pinned commits
scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh --launch      # gated launch + acceptance
scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh --stop
```

- **Gates (fail closed):** image present, `/models/ds41` mounted, Maya commit in history + `.venv`,
  every weight file present, the Backbone's `__metadata__.source` matches `BACKBONE_SOURCE` for
  the chosen WEIGHTS, comfyui.service not active, exactly two RTX PRO 6000s each ≤1024 MiB used,
  host port 8000 free.
- **Acceptance:** launched `--restart no`; only after `/v1/models` lists the served model (up to
  30 min load) is it promoted to `unless-stopped`. A failed boot cannot crash-loop the next one.
- **Tunables (env, sane defaults baked in):** `WEIGHTS`, `LANES` (1–8, default 4; each lane costs
  ~730 MiB/GPU and 78 slots), `SLOTS` (default 8528 − 78·(LANES−1)), `RAM_RECORDS` (3400),
  `RAM_POLICY` (victim | popular | recent; victim served best: warm reply 77→135 tok/s vs popular,
  2026-11-04), `SWEEP_MIN` (96), `CHECKPOINT_GB` (6), `REWIND_POINTS` (8), `NATIVE_EXTRA_ENV`
  (K=V engine experiments, passed through).
- **Metrics:** `ds4-native-metrics.service` polls the engine and serves Prometheus text on :8010
  (TTFT/ITL/e2e histograms, DSpark accept length); `vllm-stats-record.timer` writes the ledger
  every 15 min (`/var/lib/vllm-stats/stats.csv`).

## Verification (the Exactness bar)

- Engine tests run inside `--install` (`ds4n_tests`); the engine refuses to install otherwise.
- `ds4n-serve-check` (in the ds4-native repo) re-proves session resume, rewind and Shared-Round
  invariance bitwise; run it in a scheduled GPU window after engine changes.
- WARMIND's Backbone is verified against DeepSeek's by `tools/hf-backbone verify` at fetch time
  (`DERIVATIVE.json`); note the Exactness proof was run on DeepSeek's weights — the derivative
  reuses the same kernels on same-dtype/same-shape tensors, it was not re-proven end-to-end.
- Acceptance-rate canary: a silent numerics bug shows as DSpark acceptance collapsing before text
  visibly degrades — watch `drafts_kept/offered` on :8010 after any engine change.

## Measured (ledger, 2026-11-18)

Mixed agent traffic 44–85 tok/s fleet; single-stream ~60–100. Five reviewers of one diff across
4 lanes: 91→115 tok/s aggregate, all writing within ~13 s. Lanes cost a lone request ~5%.

## Gotchas

- **One GPU-owning process at a time** (flare/uncensored or this; comfyui excluded by gate).
  Every GPU experiment here is downtime for the other primary — schedule it.
- **The engram GGUF is load-bearing** (see files table). Deleting it to "free space" breaks the
  next launch — it is the runtime Engram source, the store holds only routed experts.
- `--ulimit memlock=-1 --security-opt seccomp=unconfined` are required (io_uring for store and
  Engram reads; Docker's default seccomp blocks `io_uring_setup/enter`).
- `--round-graphs-mb` 512/GPU is a measured cap: uncapped Round graphs OOM'd the GPUs after a few
  hours at 3–4 concurrent requests (2026-11-13).
- The desktop's ds4-native clone must contain `DS4N_COMMIT`; `--install` fetches, but a pinned
  commit that left main breaks the pin — bump `DS4N_COMMIT` in the launcher in the same commit as
  the engine change.
- pi has only the desktop-vllm provider (no cloud fallback): while this profile is down, pi's
  local models are down. `switch-primary.sh toggle` is the recovery path.
