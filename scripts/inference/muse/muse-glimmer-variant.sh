#!/usr/bin/env bash
# shellcheck disable=SC2034 # This sourced module exports the resolved contract.
# Resolve a legal Muse Glimmer runtime variant into one immutable configuration.
# Source this file, then call muse_resolve_variant standard|abliterated.

muse_resolve_variant() {
  if [ "$#" -ne 1 ]; then
    echo "error: muse_resolve_variant expects exactly one variant" >&2
    return 2
  fi

  local model_root="${MUSE_MODELS_ROOT:-/models}"
  case "$model_root" in
    /*) ;;
    *)
      echo "error: MUSE_MODELS_ROOT must be an absolute path (got: $model_root)" >&2
      return 2
      ;;
  esac

  MUSE_VARIANT="$1"
  case "$MUSE_VARIANT" in
    standard)
      MUSE_TARGET_REPO="meta-models/Muse-Glimmer-30B"
      MUSE_TARGET_REV="a4e59da52a7bc87ae7251dd5545c0dd437c44b68"
      MUSE_TARGET_HOST="$model_root/Muse-Glimmer-30B"
      MUSE_TARGET_CONTAINER="/models/meta-models/Muse-Glimmer-30B"
      read -r -d '' MUSE_TARGET_MANIFEST <<'EOF' || true
5a9df2d8a385b3d361ab6ae68d73586f4e775033933bd0cd863fb7f3820e6a14 5109 config.json
1fa51889b1f8d3659802dedaa27e005b81e5c58483f13ecf13f2d97306bc6e35 202 generation_config.json
cfc67e5f349f37690dfd31ed1f18bc4442a9dd32fe39a648f993cb4eb3cae678 9992 chat_template.jinja
8eef61530e1283642c77ce2e6721feb5c6f348fa055c00e90f2844a136372694 49950112952 model-00001-of-00002.safetensors
b58cc2144ba1ba1af4420f67f4ca3ced7f09298510b80464cc75018a0be14381 9603322320 model-00002-of-00002.safetensors
7d817b4dccb1b123fc6c1939356c65cee3a0ad462a5b821ac88280990a27d1ba 132674 model.safetensors.index.json
97e2a486dd9866b81f40cf4b8bc0c9ced9a7cd8a5bc65aa4cc2f4de0712dae77 1084 processor_config.json
c9dbee66967b58f31a7c27f723c3760da3526ccd0427578e8905b0abb0031c4d 28129897 tokenizer.json
781e6c74f571642c71202167b67d9255b28cc439bdda1582ff31346182f5a9c5 79936 tokenizer_config.json
EOF
      MUSE_CACHE_HOST="$model_root/sglang-cache/muse-glimmer-bf16-dflash"
      MUSE_CONTAINER_NAME="muse-glimmer-30b-bf16-dflash"
      ;;
    abliterated)
      MUSE_TARGET_REPO="mlasli/Muse-Glimmer-30B-Abliterated-BF16"
      MUSE_TARGET_REV="daf5fab76a0351a583714a92d88ebdb6eb48af35"
      MUSE_TARGET_HOST="$model_root/Muse-Glimmer-30B-Abliterated-BF16"
      MUSE_TARGET_CONTAINER="/models/mlasli/Muse-Glimmer-30B-Abliterated-BF16"
      read -r -d '' MUSE_TARGET_MANIFEST <<'EOF' || true
a9b9e923b7a26c49dc2294da2efc1d176c1ee05b310d3dafbe48ea18ccbce9e6 432 abliteration_info.json
1c235df3179388bb56e522a25543d1f9e417a25e71b162887378a4362c5e4dbc 5154 config.json
519ca0cad3bf6cb10c4f74dfb64786f651533bae2f316c609d66e0bcf5adfde6 238 generation_config.json
114f55ebdc1804c1af371197b9fdf2d6bb925966c9dfe46b73782a71bc07965e 7167 chat_template.jinja
cd53270fef03dac41c34a7cafd64cdc400cff149f59d3aff17e248892f328b5b 49902303112 model-00001-of-00002.safetensors
c459da918abc4caf363e7d47e0fddaa68e3dd8c54cd2d47c6170fde5d8308230 9651130624 model-00002-of-00002.safetensors
79f6028c3b5544f6be46607b8580d7376bf68bdc66647480fd3bfa520ad9efa3 132674 model.safetensors.index.json
700365b2a965cd87ec583d5bd7ce354ef4fb8c5a00fbd7269846bb360cac374c 28129995 tokenizer.json
b2c352bba1d2ee25295aa84e7bdaa15a2b0305b79009926bcea72516ca200d42 79985 tokenizer_config.json
EOF
      MUSE_CACHE_HOST="$model_root/sglang-cache/muse-glimmer-abliterated-bf16-dflash"
      MUSE_CONTAINER_NAME="muse-glimmer-30b-abliterated-bf16-dflash"
      ;;
    *)
      echo "error: Muse variant must be standard or abliterated (got: $MUSE_VARIANT)" >&2
      return 2
      ;;
  esac

  MUSE_DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"
  MUSE_DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"
  MUSE_DRAFT_HOST="$model_root/Muse-Glimmer-30B-assistant"
  MUSE_DRAFT_CONTAINER="/models/meta-models/Muse-Glimmer-30B-assistant"
  read -r -d '' MUSE_DRAFT_MANIFEST <<'EOF' || true
38915167b64b1e6405492aacae5b1b4511b6431163d2960b9bd25821df6fa30a 883 config.json
fd88d337eb84f8d0e6ba33a7684d7efa6722d4460ba4d6badca9699418392a84 5111976608 model.safetensors
EOF
  MUSE_RESOLVED_MODEL_ROOT="$model_root"
}
