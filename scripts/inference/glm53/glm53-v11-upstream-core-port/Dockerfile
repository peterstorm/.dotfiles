# GLM-5.3 Flash EXL3 K4 v11 — legend upstream-core-port r2 on our pinned base.
#
# Lineage note: our v9/v10 images and the legend fork build on the SAME
# digest-pinned base (verdictai/glm53-flash-exl3-k4, amd64 manifest
# 184cfdb8..., index 0f1cdcc8...). The r2 overlay replaces the same engine
# core, worker chain, b12x MLA kernels and model-side files that our v9/v10
# patches touched, so v11 adopts that tree wholesale instead of stacking on
# our own patch series.
#
# Install is manifest-driven and fail-closed: every mapping in MANIFEST.txt
# must name an existing overlay file, every destination is classified as a
# replacement of a base-image file or a new module, and both counts are pinned
# (89 replacements + 10 additions across 99 unique destinations; config/cache.py
# is mapped twice — the source tree and the venv's installed copy). New modules
# must land in a package the base image already has. Files absent from the
# manifest are rejected, so a blind directory copy cannot smuggle anything
# (upstream ships __pycache__ trees; ours are stripped and asserted absent).
FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

LABEL ai.peterstorm.inference.upstream-core-port.release=r2 \
      ai.peterstorm.inference.upstream-core-port.repo=https://github.com/legend/glm-5.3-flash-exl3-4bpw \
      ai.peterstorm.inference.upstream-core-port.commit=e65b2012d4ead12c86bd03f7e435ebace3ed3ae2 \
      ai.peterstorm.inference.upstream-core-port.overlay-sha256=c5cef15c27e3d638ba3a77dda522f877786de7c250d2ffb21e9373408cf48c26 \
      ai.peterstorm.inference.base-image=verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140 \
      ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
      org.opencontainers.image.title="GLM-5.3-Flash EXL3 K4 v11 — upstream-core-port r2 (native FP8 KV, vision)" \
      org.opencontainers.image.description="v84 base + legend r2: upstream engine-core port, sparse-MLA layer-view aliasing fix, b12x record-walk stride fix, H2D lifetime fixes, indexer write-path restore, gather clamps, rejection-sampler padding mask, scheduler Fix A/B, kvcache 0001/0002, attn 0002, cache-wipe reserve, int64 Triton fixes, native fp8_ds_mla 528B NoPE records with a capture-safe Triton writer."

# ADD auto-extracts the vendored, byte-pinned overlay archive.
ADD upstream-core-port-e65b2012d4ead12c86bd03f7e435ebace3ed3ae2.tar.gz /tmp/

COPY install-overlay.py /tmp/install-overlay.py
RUN /opt/venv/bin/python /tmp/install-overlay.py && rm -f /tmp/install-overlay.py

# The manifest travels with the image for provenance.
COPY upstream-core-port-e65b2012d4ead12c86bd03f7e435ebace3ed3ae2.tar.gz /opt/glm53/upstream-core-port-r2.tar.gz
