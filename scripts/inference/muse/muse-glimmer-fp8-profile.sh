#!/usr/bin/env bash
# shellcheck disable=SC2034 # Sourced immutable Muse FP8 profile facts.

MUSE_FP8_TARGET_REPO="RedHatAI/Muse-Glimmer-30B-FP8-block"
MUSE_FP8_TARGET_REV="8ed2e29141d4fef439b9a0e15e0a2678bc190a82"
MUSE_FP8_TARGET_HOST="${MUSE_FP8_MODELS_ROOT:-/models/vllm-cache/muse-glimmer-30b-fp8}/checkpoints/target"
MUSE_FP8_TARGET_CONTAINER="/models/RedHatAI/Muse-Glimmer-30B-FP8-block"
read -r -d '' MUSE_FP8_TARGET_MANIFEST <<'EOF' || true
5f1476af88c0462bc448f05b36eaa4c2fae3bbe3cfafc2f281c7bf452958b8f8 6491 config.json
b0e427c998641420eb4091cc85d4e15643fb57f89222834a14ec76430625b6fb 148 generation_config.json
114f55ebdc1804c1af371197b9fdf2d6bb925966c9dfe46b73782a71bc07965e 7167 chat_template.jinja
a7a144a0bfe2491c57e8f35e903a973777923879dfbe005642a4480a9dea94d8 28176516456 model-00001-of-00002.safetensors
d532cf48fc25808b5f3fd5556cc2862705303d18362640796c43d2d51a3e44e0 6216318704 model-00002-of-00002.safetensors
22970c4e6b652245647b907d908147798d49e316623f43d1c611b1a12c79ba2d 175404 model.safetensors.index.json
97e2a486dd9866b81f40cf4b8bc0c9ced9a7cd8a5bc65aa4cc2f4de0712dae77 1084 processor_config.json
c9dbee66967b58f31a7c27f723c3760da3526ccd0427578e8905b0abb0031c4d 28129897 tokenizer.json
781e6c74f571642c71202167b67d9255b28cc439bdda1582ff31346182f5a9c5 79936 tokenizer_config.json
EOF

MUSE_FP8_DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"
MUSE_FP8_DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"
MUSE_FP8_DRAFT_HOST="${MUSE_FP8_MODELS_ROOT:-/models/vllm-cache/muse-glimmer-30b-fp8}/checkpoints/dflash"
MUSE_FP8_DRAFT_CONTAINER="/models/meta-models/Muse-Glimmer-30B-assistant"
read -r -d '' MUSE_FP8_DRAFT_MANIFEST <<'EOF' || true
38915167b64b1e6405492aacae5b1b4511b6431163d2960b9bd25821df6fa30a 883 config.json
fd88d337eb84f8d0e6ba33a7684d7efa6722d4460ba4d6badca9699418392a84 5111976608 model.safetensors
EOF

MUSE_FP8_IMAGE="vllm/vllm-openai"
MUSE_FP8_IMAGE_DIGEST="sha256:413c8fbecb1204a218117c77a4ea4b3a211d5686ff99c31d82ba6dd0cec8c5a6"
MUSE_FP8_IMAGE_ID="sha256:e90b8320f680a6a7b8daff87ad08cdf063a68d869880e662fd6d2cebfef689dc"
MUSE_FP8_SERVED_MODEL="muse-glimmer-30b-fp8"
MUSE_FP8_CONTAINER_NAME="muse-glimmer-30b-fp8-vllm"
MUSE_FP8_RUNTIME_CACHE="${MUSE_FP8_MODELS_ROOT:-/models/vllm-cache/muse-glimmer-30b-fp8}/runtime"
