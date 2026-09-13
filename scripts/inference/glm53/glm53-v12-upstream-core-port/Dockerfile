# GLM-5.3 Flash EXL3 K4 v12 — legend upstream-core-port r2.1 + ported upstream
# SM120/graph-memory fixes, on our pinned base.
#
# v12 is v11.1 (legend r2.1, commit 832e6000) plus exactly four changes ported
# from the Spark TP2 source-locked image (2026-09-13 R2 update), adapted by
# hand to the legend r2.1 lineage (the upstream patches are made against
# 7f4aecc6 and do not apply to the legend overlay files):
#   PR vllm/vllm#710 "SM120 disjoint-batch BMM" (dbdf960a + 0eff5805):
#     cuBLAS on SM120/121 misreads batch matrices with overlapping strides.
#     mla_attention.py routes the two decode-path torch.bmm sites through a
#     contiguous-operand helper; dcp.py reduce-scatters a head-major
#     contiguous buffer along dim=0 instead of dim=1. Inert off SM120
#     (plain torch.bmm / original reduce_scatter preserved).
#   PR vllm/vllm#718 "Mamba recurrent state cleanup across null gaps"
#     (25fc3585): align-mode Mamba prefill leaves null gaps between states
#     awaiting retirement; the base cleanup stops at the first null block and
#     strands every retiree beyond the gap. MambaManager gains its own
#     backward walk that skips nulls, plus a _num_retired_blocks high-water
#     mark so repeat calls do not rescan history. Non-align mode defers to the
#     base stop-at-first-null behavior.
#   PR vllm/vllm#694 "post-capture memory recommendation double-count"
#     (dd8e5ca3 + d84208d4): gpu_worker.py counted the cudagraph estimate in
#     peak_activation_memory while KV admission subtracted it separately.
#     The profile peak becomes activation-only; the estimate is still billed
#     separately in available_kv_cache_memory_bytes. With
#     VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0 (set by the run script)
#     behavior is identical to v11.1; flag on fixes the double-count.
#   R2 launcher measurement: CUBLAS_WORKSPACE_CONFIG=:4096:1 saves ~140 MiB
#     per rank on SM120 (reversible env setting, set by the run script).
#
# The overlay differs from v11.1's in exactly three modified files plus one
# new overlay file and one manifest line (15 hunks):
#   upstream-g2/vllm/v1/model_executor/layers/attention/mla_attention.py
#   upstream-g2/vllm/v1/attention/ops/dcp.py
#   upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py
#   upstream-g2/vllm/v1/worker/gpu_worker.py          (new overlay file)
#   MANIFEST.txt                                      (+1 line)
# The install becomes 100 manifest mappings + 2 documented supplements = 102
# destinations (92 replacements + 10 additions); the installer's pinned counts
# are updated accordingly.
#
# Lineage and install policy are v11.1's: same digest-pinned verdictai base,
# the overlay adopted wholesale, manifest-driven fail-closed install, upstream's
# __pycache__ trees stripped from the vendored archive and asserted absent.
FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

LABEL ai.peterstorm.inference.upstream-core-port.release=v12 \
      ai.peterstorm.inference.upstream-core-port.repo=https://github.com/legend/glm-5.3-flash-exl3-4bpw \
      ai.peterstorm.inference.upstream-core-port.commit=832e6000120148f82c64acaecc56b6f96c27e6e2 \
      ai.peterstorm.inference.upstream-core-port.source-port=pr710-sm120-disjoint-bmm+pr718-mamba-null-gap+pr694-graph-memory-once+cublas-4mib \
      ai.peterstorm.inference.upstream-core-port.overlay-sha256=f36de6931717fa114476a518513fa2a1f2f307c50f9a64cdee1d6666b42cf553 \
      ai.peterstorm.inference.upstream-core-port.predecessor=r2.1-832e6000120148f82c64acaecc56b6f96c27e6e2 \
      ai.peterstorm.inference.admission-deadlock-fix="r2.1-0004-align-cap-real-footprint+0005-reserve-aging+0006-deferred-free-drain" \
      ai.peterstorm.inference.base-image=verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140 \
      ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
      org.opencontainers.image.title="GLM-5.3-Flash EXL3 K4 v12 — upstream-core-port r2.1 + SM120 disjoint-BMM / mamba null-gap / graph-memory fixes (native FP8 KV, vision)" \
      org.opencontainers.image.description="v11.1 (legend r2.1 admission deadlock fix, native fp8_ds_mla 528B NoPE records, vision) plus Spark TP2 port: PR #710 SM120/121 disjoint-batch BMM (mla_attention contiguous operands + dcp head-major reduce-scatter), PR #718 Mamba null-gap recurrent-state cleanup with retirement high-water mark, PR #694 graph-memory double-count fix (activation-only profile peak), CUBLAS_WORKSPACE_CONFIG=:4096:1 launcher setting."

# ADD auto-extracts the vendored, byte-pinned overlay archive.
ADD upstream-core-port-v12-pr710-pr718-pr694.tar.gz /tmp/

COPY install-overlay.py /tmp/install-overlay.py
RUN /opt/venv/bin/python /tmp/install-overlay.py && rm -f /tmp/install-overlay.py

# The manifest travels with the image for provenance.
COPY upstream-core-port-v12-pr710-pr718-pr694.tar.gz /opt/glm53/upstream-core-port-v12.tar.gz
