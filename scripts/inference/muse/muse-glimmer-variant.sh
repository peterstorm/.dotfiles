#!/usr/bin/env bash
# shellcheck disable=SC2034 # This sourced module exports the resolved contract.
# Resolve a legal Muse Glimmer runtime variant into one immutable configuration.
# Source this file, then call muse_resolve_variant standard|abliterated.

muse_resolve_variant() {
  if [ "$#" -ne 1 ]; then
    echo "error: muse_resolve_variant expects exactly one variant" >&2
    return 2
  fi

  MUSE_VARIANT="$1"
  case "$MUSE_VARIANT" in
    standard)
      MUSE_TARGET_REPO="meta-models/Muse-Glimmer-30B"
      MUSE_TARGET_REV="a4e59da52a7bc87ae7251dd5545c0dd437c44b68"
      MUSE_TARGET_HOST="/models/Muse-Glimmer-30B"
      MUSE_TARGET_CONTAINER="/models/meta-models/Muse-Glimmer-30B"
      MUSE_TARGET_SHA256_MANIFEST=""
      MUSE_CACHE_HOST="/models/sglang-cache/muse-glimmer-bf16-dflash"
      MUSE_CONTAINER_NAME="muse-glimmer-30b-bf16-dflash"
      MUSE_OTHER_CONTAINER_NAME="muse-glimmer-30b-abliterated-bf16-dflash"
      MUSE_DOWNLOAD_CONTAINER_NAME="muse-glimmer-model-dl"
      ;;
    abliterated)
      MUSE_TARGET_REPO="mlasli/Muse-Glimmer-30B-Abliterated-BF16"
      MUSE_TARGET_REV="daf5fab76a0351a583714a92d88ebdb6eb48af35"
      MUSE_TARGET_HOST="/models/Muse-Glimmer-30B-Abliterated-BF16"
      MUSE_TARGET_CONTAINER="/models/mlasli/Muse-Glimmer-30B-Abliterated-BF16"
      read -r -d '' MUSE_TARGET_SHA256_MANIFEST <<'EOF' || true
cd53270fef03dac41c34a7cafd64cdc400cff149f59d3aff17e248892f328b5b  model-00001-of-00002.safetensors
c459da918abc4caf363e7d47e0fddaa68e3dd8c54cd2d47c6170fde5d8308230  model-00002-of-00002.safetensors
700365b2a965cd87ec583d5bd7ce354ef4fb8c5a00fbd7269846bb360cac374c  tokenizer.json
EOF
      MUSE_CACHE_HOST="/models/sglang-cache/muse-glimmer-abliterated-bf16-dflash"
      MUSE_CONTAINER_NAME="muse-glimmer-30b-abliterated-bf16-dflash"
      MUSE_OTHER_CONTAINER_NAME="muse-glimmer-30b-bf16-dflash"
      MUSE_DOWNLOAD_CONTAINER_NAME="muse-glimmer-abliterated-model-dl"
      ;;
    *)
      echo "error: Muse variant must be standard or abliterated (got: $MUSE_VARIANT)" >&2
      return 2
      ;;
  esac

  MUSE_DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"
  MUSE_DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"
  MUSE_DRAFT_HOST="/models/Muse-Glimmer-30B-assistant"
  MUSE_DRAFT_CONTAINER="/models/meta-models/Muse-Glimmer-30B-assistant"
}
