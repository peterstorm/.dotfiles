# GLM-5.3 Flash v12 — deployment receipt — 2026-09-14

Companion to `2026-09-07-glm53-v11.1-r2.1.md` and the research receipt
`docs/research/2026-09-13-glm53-v12-source-port-research.md`. v12 = v11.1
(legend upstream-core-port r2.1, commit `832e6000`) plus exactly the four
changes ported from the Spark TP2 source-locked image (2026-09-13 R2 update),
adapted by hand to the legend r2.1 lineage. The upstream patches are made
against `7f4aecc6` and do not apply to the legend overlay files (dry-run
failed on `single_type_kv_cache_manager.py:2057`), so the port is by hand.

## Identity

- Served model: `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12`
- Overlay: `legend-r2.1-832e6000120148f82c64acaecc56b6f96c27e6e2+ported`
  (source-port `pr710-sm120-disjoint-bmm+pr718-mamba-null-gap+pr694-graph-memory-once+cublas-4mib`)
- Base: `verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` (unchanged from v11.1)
- Overlay archive: `scripts/inference/glm53/glm53-v12-upstream-core-port/upstream-core-port-v12-pr710-pr718-pr694.tar.gz`,
  SHA-256 `898db34d0535fbd32312f7071a9354e10174aeed623dafba2ee4f4d9aff5d288`, 102 files
  (v11.1's 101 + the new `upstream-g2/vllm/v1/worker/gpu_worker.py`)
- Image id: **unrecorded** — the build runs on the desktop host
  (`scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v12-image.sh`);
  record the derived id as `IMAGE_CONFIG` in
  `scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v12.sh` before serving.
- Runtime: TP2 / EP2 / DCP2 (`a2a`), FP8 DS-MLA KV (528-byte GLM_NOPE),
  built-in probabilistic MTP3, prefix cache, vision — identical serving shape
  to v11.1.

## The four ported changes

1. **PR vllm/vllm#710 — SM120/121 disjoint-batch BMM** (`dbdf960a` + `0eff5805`).
   cuBLAS on SM120/121 misreads batch matrices with overlapping strides.
   - `mla_attention.py`: new `_bmm_with_disjoint_batches` helper routes the two
     decode-path `torch.bmm` sites (query up-projection, v-up projection)
     through contiguous operands on SM120; plain `torch.bmm` preserved
     otherwise. `[SM120-DISJOINT-BMM]`.
   - `dcp.py`: `cp_lse_ag_out_rs` reduce-scatters a head-major contiguous
     buffer along `dim=0` instead of `dim=1` on SM120; the original branch is
     preserved. `[SM120-DISJOINT-BMM]`.
2. **PR vllm/vllm#718 — Mamba recurrent-state cleanup across null gaps**
   (`25fc3585`, backport of upstream `#55450`). Align-mode Mamba prefill
   leaves null gaps between state blocks awaiting retirement; the base cleanup
   stops at the first null block and strands every retiree beyond the gap.
   - `single_type_kv_cache_manager.py`: `MambaManager` gains its own backward
     walk that skips nulls, plus a `_num_retired_blocks` high-water mark so
     repeat calls never rescan already-retired history; the cursor drains on
     free. Non-align mode defers to the base stop-at-first-null behavior.
     `[MAMBA-NULL-GAP]`. The base method is byte-identical to v11.1's.
3. **PR vllm/vllm#694 — post-capture memory recommendation double-count**
   (`dd8e5ca3` + `d84208d4`). `gpu_worker.py` counted the cudagraph estimate in
   `peak_activation_memory` while KV admission subtracted it separately.
   - `gpu_worker.py` (new overlay file): the profile peak becomes
     activation-only; the estimate is still billed separately in
     `available_kv_cache_memory_bytes`. With
     `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` (set by the run script)
     behavior is identical to v11.1; flag on fixes the double-count.
     `[GRAPH-MEMORY-ONCE]`.
4. **R2 launcher measurement — `CUBLAS_WORKSPACE_CONFIG=:4096:1`**. The
   R2-measured 4 MiB cuBLAS workspace saved ~140 MiB per rank on SM120
   (reversible launcher setting, set by the run script).

## What is preserved from v11.1

Everything qualified in the v11.1 r2.1 receipt: the r2 engine-core port,
0004 align-cap real-footprint billing (legacy kill-switch still never set),
0005 reserve aging, 0006 deferred-free drain, r2's Fix B chunk cap removal,
native fp8_ds_mla 528-byte GLM_NOPE records, vision, MTP3, TP2/EP/DCP2 a2a
serving shape, admission knobs (`VLLM_MAMBA_STATE_PROTECT=16`,
`_AGE=128`), and `--prefill-schedule-interval 8` decode protection.

## Static contract (no Docker, no GPU)

`tests/glm53-flash-exl3-k4-vllm-sm120-v12-contract.sh` — PASS on 2026-09-14:

- byte-pinned archive (digest above), 102 files, no compiled artifacts;
- exactly three modified files + the new gpu_worker.py + one manifest line
  against v11.1's archive; every kernel/model file byte-identical;
- the manifest extends v11.1's by exactly one mapping (the gpu_worker.py
  replacement), 100 mappings total;
- ported-file digests pinned (single_type `917fd3d5…`, mla_attention
  `33d0fad4…`, dcp `5f5cc3e7…`, gpu_worker `2ddbc929…`);
- the three r2.1 fix sites plus the four port sites present; the raw bmm call
  sites, the v11.1 double-count line, and `_num_retired_blocks` absent where
  they are replaced; the base stop-at-first-null behavior preserved; the
  v11.1 overlay does not carry gpu_worker.py;
- installer counts moved to 100 mappings / 102 destinations / 92 replacements
  / 10 additions with seven fix markers (3 r2.1 + 4 v12);
- every serve/switch/build pin coherent (serving shape, `CUBLAS_WORKSPACE_CONFIG=:4096:1`,
  `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`, source-port
  labels, IMAGE dual-state, catalog/pi model entry).

The embedded focused CPU test (runs inside the built image on the desktop)
proves the ported cleanup crosses null gaps, is idempotent, never rescans
history, and defers to the base stop-at-first-null behavior outside align mode.

## Operator steps (desktop host)

```bash
ssh desktop
cd ~/dotfiles   # or wherever the repo lives on desktop
scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v12-image.sh
# record derived_id as IMAGE_CONFIG in run-glm53-flash-exl3-k4-vllm-sm120-v12.sh
scripts/inference/glm53/switch-glm53-exl3-profile-v12.sh start
```

The pull script builds CPU-only (fail-closed installer + content proof +
focused CPU test), records the identity receipt, and refuses to serve while
`IMAGE_CONFIG` is unrecorded. The switcher runs the transactional
restart=no launch, records exact KV capacity with the boot receipt, verifies
authenticated exact-model readiness, then promotes to restart=unless-stopped.

## Qualification gates (pending)

- boot + authenticated readiness + KV-capacity receipt (switcher, above);
- mixed-traffic, long-context, and shared-prefix churn gates
  (`benchmarks/vllm-tps/glm53-gates.py`), plus v12-specific ITL/memory
  observations for what PR #710/#718/#694 changed;
- >=24h soak before promotion; rollback restores whatever profile set was
  running before — v11.1 is the qualified release and is never conflated with
  a failed v12 acceptance.

## Stage follow-ups (separate children, never conflated with v12)

- vision chunking + coherent DCP scratch = v12-memory;
- atomic recurrent LMCache = v12-cache.
