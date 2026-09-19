# GLM-5.3 Flash Spark TP2 (v14) — upstream evidence

Vendored upstream reference for the v14 deployment profile:

- **Source:** https://github.com/local-inference-lab/rtx6kpro/blob/master/models/glm-5.3-flash-spark-tp2.md
- **Vendored file:** `upstream-glm-5.3-flash-spark-tp2.md`
- **SHA-256:** `1afc3a6700471e22bbe60db60e0de7e42527d5bdc83f2c218dbdd51f5607bd74`
- **Fetched:** 2026-09-19

The deployment contract the repository pins against (all verified to the
upstream preset `glm53-spark-tp2` through the image's `--print-config`
interface, not by reading the doc):

| Setting | Upstream doc | Preset value pinned by v14 |
|---|---|---|
| Image | `ghcr.io/local-inference-lab/vllm:karmic-kraken-beta` | resolved to one image id by the pull script |
| Checkpoint | `GLM-5.3-Flash-NVFP4-Spark` | `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` @ `a608241037e4c2565356bff7ca293f2133888f88` (pre-downloaded, offline-pinned) |
| Parallelism | TP2 / DCP2 | `tensor-parallel-size: 2`, `decode-context-parallel-size: 2` |
| Speculation | MTP3 | `mode: mtp`, `draft-tokens: 3` |
| Request slots | 4 | `max-num-seqs: 4` |
| Prefill budget | 3072 tokens | `max-num-batched-tokens: 3072` |
| KV allocation | 3996 MiB per GPU | `kv-cache-memory-bytes: 4190109696` |
| Context capacity | About 983k GPU-only; 924k with LMCache | `max-model-len: -1` (memory-resolved at boot) |
| GPU memory util | — | `gpu-memory-utilization: 0.985` |
| Vision | Enabled, no one-image admission cap | preset default (kept) |
| Hardware profile | RTX PRO 6000 Workstation | `rtx-pro-6000-pcie` |
| CUDA graphs | 1/2/4/8/12/16 rows | preset default (kept) |

## Driver / CUDA compatibility evidence (2026-09-19)

How we know the host driver runs this image — probes, not version tables:

| Component | Host / image | Evidence |
|---|---|---|
| Host driver | **595.91.07** (nvidia-smi; flake pin; supports CUDA 13.2) | nvidia-smi query |
| Image runtime | torch 2.14.0a0 built for **CUDA 13.4** | inside-image import |
| cuBLAS | image build | 1 matmul + 1 assertion on device 0 — ✅ |
| cuDNN | 9.25.0 | 1 conv on device 0 — ✅ |
| NCCL | 2.30.7 | real two-GPU allreduce (8 MiB tensor × 2 ranks, `torch.distributed`) — ✅ |
| Upstream tested driver | 615.71.09 | doc reference only; not required for runtime (CUDA minor-version compatibility) |

The launcher re-runs all three probes fail-closed at every `--launch` (cuBLAS
+ cuDNN on the first GPU, NCCL allreduce across both), so a driver regression
or a rebuilt image failing to load fails the switch with a clear error before
any serving container starts. The remaining unproven layer (B12X kernels,
full model load, graph capture) is covered by the switch's boot acceptance
(health + authenticated exact `/v1/models`) and the runbook's smoke step.

## Boot acceptance evidence (2026-09-19 11:12 UTC)

- `HEALTHY + AUTHENTICATED + EXACT MODEL` on the first completed swap
- Resolved `max_model_len`: **983,040** (auto-fit from 1,048,576 to fit the
  3.99 GiB/GPU KV budget) — identical to the registered catalog value
- GPU KV cache: 986,295 tokens; concurrency for full-context requests: 1.00×
- Serving config from the boot log matches the preset table above line-for-line
  (TP2/DCP2, fp8 KV, block 256, cudagraphs 1/2/4/8/12/16, MTP3, glm45/glm47
  parsers, revision pin)
- Smoke completion returned the exact requested string with a reasoning
  stream through the authenticated endpoint
- Boot receipt: `~/.local/state/glm53/flash-spark-tp2-v14-boot-receipt.txt`

## Repository deviations (all deliberate, documented in the v14 runbook and
scripts):

1. **Served model id** — `SERVED_MODEL_NAME=glm-5.3-flash-spark-tp2-v14`
   overrides the preset's `GLM-5.3-Flash` so Pi/benchmark attestation can pin
   the exact runtime profile (launcher precedence: native arg > environment
   alias > preset; proven by `--print-config` in the pull script).
2. **Restart policy** — launch with `--restart no`, promote to
   `--restart=unless-stopped` only after an accepted boot (repository
   transactional pattern; the doc's unless-stopped is the promoted end state).
3. **Checkpoint** — the doc downloads
   `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` into a named volume on
   first boot; v14 pre-downloads the pinned revision
   (`a608241037e4c2565356bff7ca293f2133888f88`) into
   `/models/hf-cache/glm53-flash-spark-tp2-v14` and serves with
   `HF_HUB_OFFLINE=1` + `MODEL_REVISION` (the engine can never fetch a
   different revision, and the cache stays verifiable from the host).
4. **API key** — `VLLM_API_KEY` is passed through the repository's synchronized
   credential contract (the doc leaves the API on a trusted network or asks
   for authentication; this deployment authenticates).
