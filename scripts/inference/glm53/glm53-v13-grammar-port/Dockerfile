# GLM-5.3 Flash EXL3 K4 v13 — v12 plus the grammar redesign port and two
# upstream hardening fixes, on our pinned base.
#
# v13 is v12 (legend upstream-core-port r2.1, commit 832e6000) plus exactly
# three changes ported by hand from upstream, added as four new overlay files:
#   PR vllm/vllm#52477 "grammar redesign" (fixed-width stride):
#     structured/guided decoding combined with MTP3 speculative decoding
#     crashes the engine in _build_grammar_row_mapping — the v11.1/v12 crash
#     loop. The redesign replaces the row-mapping assertion with a
#     fixed-width stride over the speculative token windows:
#       worker/gpu/structured_outputs.py  full rewrite (new overlay file)
#       structured_output/__init__.py     producer ported to the stride
#       structured_output/utils.py        dormant consumer ported to the stride
#       worker/gpu/warmup.py              bitmask resized for the stride
#   upstream vllm/vllm#53046 "FSM validate-before-accept" (producer):
#     when a reasoning model ends its think block mid-token-window, the
#     bitmask row for that window is sampled from the previous window's FSM
#     state instead of the FSM state after the think block closes; the
#     producer now validates before accepting. Confirmed missing from the
#     fork base before porting (grepped container files).
#   upstream vllm/vllm#55455 "warmup defers adaptive verification":
#     warmup runs DSpark adaptive verification; upstream defers it during
#     warmup (body moved to _warmup_kernels). Confirmed missing from the
#     fork base before porting (grepped container files).
#
# The overlay differs from v12's in exactly four new overlay files and four
# manifest lines; every other overlay file is byte-identical to v12's. All
# four are replacements of base-image files (the base ships them; BASE-SHAS
# pins their image shas), so the install becomes 104 manifest mappings + 2
# documented supplements = 106 destinations (96 replacements + 10 additions);
# the installer's pinned counts are updated accordingly.
#
# Lineage and install policy are v12's: same digest-pinned verdictai base,
# the overlay adopted wholesale, manifest-driven fail-closed install, upstream's
# __pycache__ trees stripped from the vendored archive and asserted absent.
FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140

LABEL ai.peterstorm.inference.upstream-core-port.release=v13 \
      ai.peterstorm.inference.upstream-core-port.repo=https://github.com/legend/glm-5.3-flash-exl3-4bpw \
      ai.peterstorm.inference.upstream-core-port.commit=832e6000120148f82c64acaecc56b6f96c27e6e2 \
      ai.peterstorm.inference.upstream-core-port.source-port=pr52477-grammar-port+pr53046-fsm-validate+pr55455-warmup-defer \
      ai.peterstorm.inference.upstream-core-port.overlay-sha256=685f6966d72cc643a47a2291ca897f4f09ac3ba42e09bf8663dc5f5028db4ae6 \
      ai.peterstorm.inference.upstream-core-port.predecessor=v12-832e6000120148f82c64acaecc56b6f96c27e6e2 \
      ai.peterstorm.inference.admission-deadlock-fix="r2.1-0004-align-cap-real-footprint+0005-reserve-aging+0006-deferred-free-drain" \
      ai.peterstorm.inference.base-image=verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140 \
      ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b \
      org.opencontainers.image.title="GLM-5.3-Flash EXL3 K4 v13 — v12 + grammar redesign (fixed-width stride) / FSM validate-before-accept / warmup-defer fixes (native FP8 KV, vision)" \
      org.opencontainers.image.description="v12 (legend r2.1 admission deadlock fix + SM120 disjoint-BMM + mamba null-gap cleanup + graph-memory-once, native fp8_ds_mla 528B NoPE records, vision) plus grammar redesign port: PR #52477 fixed-width stride replacing the _build_grammar_row_mapping crash (structured decoding + MTP3 no longer kills the engine), upstream #53046 FSM validate-before-accept for reasoning models ending mid-window, upstream #55455 warmup defers adaptive verification."

# ADD auto-extracts the vendored, byte-pinned overlay archive.
ADD upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz /tmp/

COPY install-overlay.py /tmp/install-overlay.py
RUN /opt/venv/bin/python /tmp/install-overlay.py && rm -f /tmp/install-overlay.py

# The manifest travels with the image for provenance.
COPY upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz /opt/glm53/upstream-core-port-v13.tar.gz
