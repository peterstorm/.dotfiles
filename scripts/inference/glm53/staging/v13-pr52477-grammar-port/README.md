# GLM-5.3 v13 — grammar port + upstream hardening (#52477, #53046, #55455) (STAGED, NOT SERVED)

Status: **authored + CPU-verified, unserved candidate.** Fixes the structured-output
crash/corruption that took v12 into a crash loop on 2026-09-14, plus two upstream
hardening fixes folded in 2026-09-14 (both confirmed missing from the fork base).
NOT promoted; v11.1 remains the served release.

## What this fixes
`_build_grammar_row_mapping` in `worker/gpu/structured_outputs.py` asserts
`0 <= num_active_drafts <= num_source_drafts`. Under MTP-3 + DSpark adaptive
verification the GPU finalizes MORE active drafts than the scheduler scheduled →
`AssertionError` → EngineDeadError → (with restart=unless-stopped) crash loop.
The bug is BASE vLLM (identical file in v11.1 and v12), so v11.1 is vulnerable to
the same structured/tool-call traffic; it just wasn't receiving it.

## The port
Re-implements the TARGET design of vllm-project/vllm#52477 "Drive grammar masks
from GPU logit counts" (open/draft; branch `gpu-driven-grammar-mask-stride`).
#52477 does NOT apply as a patch: this fork diverged from the PR base in both
consumer files. So it is a hand re-implementation of the DESIGN, not a `git apply`:

- **`worker/gpu/structured_outputs.py`** — full rewrite. Deletes the compacted
  `_build_grammar_row_mapping` CPU mapping. Each grammar request now owns a
  fixed-width block of `mask_stride` (= `decode_query_len`, threaded in by
  model_runner's FORK-COMPAT shim, which already offered `mask_stride`). The
  Triton kernel launches once per grammar request and reads the request's actual
  logit count from device-side `input_batch.cu_num_logits`, applying only active
  positions. No CPU compaction, no scheduled-draft count → the stale hand-off can
  no longer assert or mis-map.
- **`structured_output/__init__.py`** (producer) — at PR base; mechanical port.
  Emits fixed-width `max_masks_per_req = num_spec_tokens + num_bonus` rows/req.
  - **[#53046-PORT]** (upstream #53046, merged 2026-08-21) — in `grammar_bitmask`,
    when reasoning ends mid-window, validate the token (`validate_tokens`) before
    accepting: the drafts between the marker and the bitmask predate the bitmask,
    and an invalid draft must not corrupt the grammar state (the
    spurious-FSM-error-after-speculative-reasoning-end class). Confirmed missing
    from the fork base (unguarded accept at the per-token site).
- **`structured_output/utils.py`** (MRV1/V1-runner consumer) — DORMANT for GLM
  (GLM uses MRV2/GPU runner). Ported to fixed-width stride for consistency.
- **`worker/gpu/warmup.py`** — synthetic warmup bitmask sized to
  `len(req_ids) * decode_query_len` to match the worker's new assertion.
- **`worker/gpu/warmup.py`** — [#55455-PORT] (upstream #55455, merged
  2026-09-06) — `warmup_kernels` now defers DSpark adaptive verification:
  `model_runner.adaptive_verification = None` during warmup, restored in
  `finally` (body moved to `_warmup_kernels`). Adaptive costs are calibrated
  during capture, so warmup must exercise fixed draft counts. Confirmed missing
  from the fork base (no `adaptive_verification` reference in the container's
  warmup.py).

## Verified (CPU-only, no GPU, v11.1 untouched)
- All 4 files byte-compile against the image interpreter (py3.12.3; re-verified
  2026-09-14 after the expanded port).
- Diff audit: crash design removed from live code (header comment only);
  `cumulative_index` gone from producer; `max_masks_per_req` drives all sites;
  `[PR53046-PORT]` and `[PR55455-PORT]` markers present.
- Base provenance pinned in BASE-SHAS.txt (ported FROM those image shas).

## NOT done — required before promotion (BLOCKED by "don't take down v11.1")
1. Assemble v13 overlay (tarball + install-overlay.py w/ bumped counts + new fix
   marker `[PR52477-PORT]` + Dockerfile) + run/pull/switch scripts + catalog +
   pi model entry + static contract test, mirroring the v12 methodology.
2. Build image CPU-only (fail-closed installer + content proof).
3. **GPU acceptance — REQUIRES A SERVING SLOT (both GPUs are in v11.1's TP2 group):**
   - glm53-gates.py mixed-traffic + shared-prefix churn, WITH structured/tool-call
     + MTP-3 traffic (the exact shape that crashed v12).
   - >=24h soak before promotion over v11.1.

## ⚠ Failure mode
A wrong grammar-mask kernel does NOT crash — it silently samples UNCONSTRAINED
tokens (see vLLM issue #54437), corrupting JSON/tool-call output. Do not promote
on the CPU checks alone; the GPU grammar-correctness gate is mandatory.
