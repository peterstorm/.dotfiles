# GLM-5.3 Flash EXL3 K4 v11.1 — legend upstream-core-port r2.1 on our pinned base.
#
# v11.1 is v11 (legend r2, commit e65b2012) plus exactly the one upstream commit
# that follows it: 832e6000 "r2.1: admission deadlock fix". r2 wedges the engine
# whenever a long session reaches the head of the waiting queue: the align-mode
# admission cap billed null slots as real demand (~10x inflation for long
# prompts), the scheduler breaks its waiting loop on the first refusal, and
# nothing behind the refused request is ever tried again — running=0,
# waiting=N, KV usage 0%, /health still 200. Reproduced on the desktop on
# 2026-09-06 under three configurations (reserve 16: ~30 s; reserve 0: ~4.5 min;
# a single 89%-KV chat). r2.1 carries three fixes (upstream's own numbering):
#   0004 align cap bills the real footprint (spec+2+ckpt+partial per mamba
#        group, prompt-length independent); VLLM_MAMBA_ALIGN_CAP_LEGACY=1 is the
#        kill-switch and must stay unset here.
#   0005 a request blocked SOLELY by VLLM_MAMBA_STATE_PROTECT's reserve ages out
#        after VLLM_MAMBA_STATE_PROTECT_AGE attempts (default 128) and is
#        admitted on demand alone, with a logged warning.
#   0006 deferred frees drain on 0-token steps too (inert without a KV-transfer
#        connector, harmless to carry).
# r2.1 also REMOVES r2's "Fix B" decode-aware 512-token prefill chunk cap
# upstream ("obsolete after the cache-wipe fix; interval-only decode protection
# verified at ITL p95 22 ms") — a throughput/latency behaviour change this
# version takes deliberately, so it must re-qualify under the mixed-traffic gate.
#
# The overlay differs from v11's in exactly three files (13 hunks):
#   upstream-g1/vllm/v1/core/kv_cache_manager.py
#   upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py
#   upstream-g1/vllm/v1/core/sched/scheduler.py
# MANIFEST.txt is byte-identical, so the install stays 99 manifest mappings +
# 2 documented supplements = 101 destinations (91 replacements + 10 additions),
# and the install script's pinned counts are unchanged from v11.
#
# Lineage and install policy are v11's: same digest-pinned verdictai base, the
# overlay adopted wholesale, manifest-driven fail-closed install, upstream's
# __pycache__ trees stripped from the vendored archive and asserted absent.
FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

LABEL ai.peterstorm.inference.upstream-core-port.release=r2.1 \
      ai.peterstorm.inference.upstream-core-port.repo=https://github.com/legend/glm-5.3-flash-exl3-4bpw \
      ai.peterstorm.inference.upstream-core-port.commit=832e6000120148f82c64acaecc56b6f96c27e6e2 \
      ai.peterstorm.inference.upstream-core-port.overlay-sha256=91c370ce94e93ef73b09974a2b627cf6b26e8bd3f5a1d4a88022c56742db3c83 \
      ai.peterstorm.inference.upstream-core-port.predecessor=r2-e65b2012d4ead12c86bd03f7e435ebace3ed3ae2 \
      ai.peterstorm.inference.admission-deadlock-fix="r2.1-0004-align-cap-real-footprint+0005-reserve-aging+0006-deferred-free-drain" \
      ai.peterstorm.inference.base-image=verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140 \
      ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
      org.opencontainers.image.title="GLM-5.3-Flash EXL3 K4 v11.1 — upstream-core-port r2.1 (admission deadlock fix, native FP8 KV, vision)" \
      org.opencontainers.image.description="v84 base + legend r2.1: everything in r2 (upstream engine-core port, sparse-MLA layer-view aliasing fix, b12x record-walk stride fix, H2D lifetime fixes, indexer write-path restore, gather clamps, rejection-sampler padding mask, scheduler Fix A, kvcache 0001/0002, attn 0002, cache-wipe reserve, int64 Triton fixes, native fp8_ds_mla 528B NoPE records) plus the r2.1 admission deadlock fix (0004 align-cap real-footprint billing, 0005 reserve aging escape, 0006 unconditional deferred-free drain); r2's Fix B prefill chunk cap is removed upstream."

# ADD auto-extracts the vendored, byte-pinned overlay archive.
ADD upstream-core-port-832e6000120148f82c64acaecc56b6f96c27e6e2.tar.gz /tmp/

COPY install-overlay.py /tmp/install-overlay.py
RUN /opt/venv/bin/python /tmp/install-overlay.py && rm -f /tmp/install-overlay.py

# The manifest travels with the image for provenance.
COPY upstream-core-port-832e6000120148f82c64acaecc56b6f96c27e6e2.tar.gz /opt/glm53/upstream-core-port-r2.1.tar.gz
