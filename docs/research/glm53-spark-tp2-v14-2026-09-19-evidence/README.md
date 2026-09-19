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
| Checkpoint | `GLM-5.3-Flash-NVFP4-Spark` | `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` |
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

Repository deviations (all deliberate, documented in the v14 runbook and
scripts):

1. **Served model id** — `SERVED_MODEL_NAME=glm-5.3-flash-spark-tp2-v14`
   overrides the preset's `GLM-5.3-Flash` so Pi/benchmark attestation can pin
   the exact runtime profile (launcher precedence: native arg > environment
   alias > preset; proven by `--print-config` in the pull script).
2. **Restart policy** — launch with `--restart no`, promote to
   `--restart=unless-stopped` only after an accepted boot (repository
   transactional pattern; the doc's unless-stopped is the promoted end state).
3. **API key** — `VLLM_API_KEY` is passed through the repository's synchronized
   credential contract (the doc leaves the API on a trusted network or asks
   for authentication; this deployment authenticates).
