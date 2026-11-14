#!/usr/bin/env bash
# Static release contract for the GLM-5.3 v16 Hyperflare TP2 profile.
#
# v16 serves nvidia/GLM-5.3-Flash-FP4-Local through NVIDIA Hyperflare (the
# AzallazA fork at hyperflare-glm-20261112) as the recipe's TP2/DCP2 package.
# The contract proves, without Docker or a GPU, that the build/download/
# export/run/switch scripts agree on every pin (fork commit, checkpoint
# revision, image tag, package naming, served id), that the vendored recipe
# scripts are byte-identical to upstream's, that the monitoring bridge and
# the Pi catalog carry the profile, and that the runbook records the
# decisions that differ from the recipe's test system.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
OVERLAY="$GLM/glm53-v16-hyperflare"
DOCKERFILE="$OVERLAY/Dockerfile"
BUILD="$GLM/build-glm53-flash-hyperflare-tp2-v16-image.sh"
DL="$GLM/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh"
EXPORT="$GLM/export-glm53-flash-hyperflare-tp2-v16.sh"
RUN="$GLM/run-glm53-flash-hyperflare-tp2-v16.sh"
SWITCH="$GLM/switch-glm53-hyperflare-tp2-v16.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-hyperflare-tp2-v16-runbook-2026-11-13.md"
DESKTOP="$ROOT/machines/desktop/default.nix"

FORK_COMMIT="ac9136b02c7c523f12d6e628e9d94f41006312ea"
IMAGE="peterstorm/glm53-hyperflare:ac9136b-cu131"
REPO="nvidia/GLM-5.3-Flash-FP4-Local"
REVISION="76348ddb2be2e35e39ecfc00e75dc07703f4f3d5"
SERVED_MODEL="glm-5.3-flash-hyperflare-tp2-v16"
CONTAINER="glm53-flash-hyperflare-tp2-v16"
# git blob ids of the recipe folder's files at recipe commit 9a57f78e.
EXPORT_BLOB="f2bcc006e3b63c0add107396bfe8f85f4832e502"
SERVE_BLOB="a7fa2172a9e327070db43444c1d2094aef143315"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "${1#"$ROOT"/} is missing: $2"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "${1#"$ROOT"/} must not contain: $2"; }

for file in "$DOCKERFILE" "$BUILD" "$DL" "$EXPORT" "$RUN" "$SWITCH" "$RUNBOOK"; do
  [ -f "$file" ] || fail "missing ${file#"$ROOT"/}"
done
for script in "$BUILD" "$DL" "$EXPORT" "$RUN" "$SWITCH"; do
  [ -x "$script" ] || fail "${script#"$ROOT"/} is not executable"
  bash -n "$script"
done

# Vendored recipe scripts are upstream's bytes.
[ "$(git -C "$ROOT" hash-object "$OVERLAY/export-glm-tp2.sh")" = "$EXPORT_BLOB" ] ||
  fail "vendored export-glm-tp2.sh drifted from recipe blob $EXPORT_BLOB"
[ "$(git -C "$ROOT" hash-object "$OVERLAY/serve-glm-tp2.sh")" = "$SERVE_BLOB" ] ||
  fail "vendored serve-glm-tp2.sh drifted from recipe blob $SERVE_BLOB"
contains "$EXPORT" "RECIPE_EXPORT_BLOB=\"$EXPORT_BLOB\""

# One fork commit, one image tag, everywhere.
contains "$DOCKERFILE" "ARG FORK_COMMIT=$FORK_COMMIT"
contains "$DOCKERFILE" 'ARG FORK_TAG=hyperflare-glm-20261112'
contains "$DOCKERFILE" 'test "$(git rev-parse HEAD)" = "$FORK_COMMIT"'
contains "$DOCKERFILE" 'uv sync --locked --extra prepare --extra test'
contains "$DOCKERFILE" 'cargo build --locked --release --manifest-path flare-cli/Cargo.toml'
contains "$DOCKERFILE" 'for p in tp3-patches/*.patch'
contains "$DOCKERFILE" 'tp3-tools/make-b12x-overlay.sh'
contains "$DOCKERFILE" 'ai.peterstorm.inference.hyperflare-commit=$FORK_COMMIT'
grep -Eq '^FROM nvidia/cuda:13\.1\.1-devel-ubuntu24\.04@sha256:[0-9a-f]{64}$' "$DOCKERFILE" ||
  fail "CUDA base image is not digest-pinned 13.1.1-devel"
grep -Eq '^FROM ghcr\.io/astral-sh/uv:0\.11\.29@sha256:[0-9a-f]{64} AS uv$' "$DOCKERFILE" ||
  fail "uv image is not digest-pinned 0.11.29"
for script in "$BUILD" "$EXPORT" "$RUN"; do
  contains "$script" "IMAGE=\"$IMAGE\""
  contains "$script" "HYPERFLARE_COMMIT=\"$FORK_COMMIT\""
done

# Checkpoint: pinned revision, directory named for the model, verified gate.
contains "$DL" "REPO=\"$REPO\""
contains "$DL" "REV=\"$REVISION\""
contains "$DL" 'CKPT_HOST="$ROOT_HOST/glm53-fp4-local"'
contains "$DL" 'EXPECTED_SHARDS=40'
contains "$DL" 'HF_HUB_DISABLE_XET=1'
contains "$DL" '--memory "$MEMORY_CAP"'
grep -Eq '^IMAGE="python@sha256:[0-9a-f]{64}"$' "$DL" || fail "download image is not digest-pinned"
contains "$EXPORT" 'download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh" --verify'
contains "$EXPORT" '-v "$CKPT_HOST:/ckpt/glm53-fp4-local:ro"'
contains "$EXPORT" '--ulimit memlock=-1'
# flare (Rust) finds its store via getpwuid, the exporter (Python) via $HOME:
# uid 1000's passwd home must be the mounted /flare-home, and only uid 1000 runs.
contains "$DOCKERFILE" 'usermod -d /flare-home ubuntu'
contains "$EXPORT" '[ "$(id -u)" = 1000 ]'
contains "$RUN" '[ "$(id -u)" = 1000 ]'
contains "$RUN" '.cache/flare/cores/models/'
# b12x's io_uring weight loader: headers in the image, syscalls allowed.
contains "$EXPORT" '--security-opt seccomp=unconfined'
contains "$RUN" '--security-opt seccomp=unconfined'
contains "$DOCKERFILE" 'liburing-dev ninja-build'
contains "$RUN" "CHECKPOINT=\"$REPO@$REVISION\""

# Package: produced by the export receipt, consumed by name@version only.
contains "$EXPORT" 'PACKAGE_RECEIPT="$ROOT_HOST/package-v16.txt"'
contains "$RUN" 'PACKAGE_RECEIPT="$ROOT_HOST/package-v16.txt"'
contains "$RUN" '^glm53-fp4-local@gb202-tp2-[0-9]+$'

# Serve flags: the recipe's TP2 serve plus our port/host/id/key.
contains "$RUN" "SERVED_MODEL=\"$SERVED_MODEL\""
contains "$RUN" "NAME=\"$CONTAINER\""
contains "$RUN" '--gpus 0,1 --host 0.0.0.0 --port 8000'
contains "$RUN" '--prefix-cache-memory "$PREFIX_CACHE" --mtp-draft-tokens 5'
contains "$RUN" '--scheduler-policy "$SCHEDULER"'
contains "$RUN" 'PREFIX_CACHE="${PREFIX_CACHE:-16G}"'
contains "$RUN" 'SCHEDULER="${SCHEDULER:-interactive}"'
contains "$RUN" '--api-key-file /run/inference/api-key'
contains "$RUN" '-v "$KEYFILE:/run/inference/api-key:ro"'
contains "$RUN" '--restart no'
contains "$RUN" '--ulimit memlock=-1'
contains "$RUN" 'gpuPowerLimitWatts'
contains "$RUN" 'comfyui.service is active'
absent "$RUN" 'VLLM_API_KEY=$VLLM_API_KEY'

# Switcher: transactional, runtime-neutral idle gate, bridge is acceptance.
contains "$SWITCH" "TARGET=\"$CONTAINER\""
contains "$SWITCH" "EXPECTED_MODEL=\"$SERVED_MODEL\""
contains "$SWITCH" 'http://127.0.0.1:8010/metrics'
contains "$SWITCH" 'http://127.0.0.1:8011/metrics'
contains "$SWITCH" 'require_metrics_bridge'
contains "$SWITCH" 'promote_restart_policy'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$CATALOG" "  $CONTAINER"

# Monitoring and client catalog.
contains "$DESKTOP" 'systemd.services.hyperflare-metrics'
jq -e --arg id "$SERVED_MODEL" '
  .providers["desktop-vllm"].models
  | map(select(.id == $id))
  | length == 1 and .[0].contextWindow == 1048576 and (.[0].input | index("image") != null)
' "$PI_MODELS" >/dev/null || fail "pi/models.json does not carry $SERVED_MODEL with 1M context and image input"

# Runbook records the decisions that differ from the recipe's test system.
contains "$RUNBOOK" "$FORK_COMMIT"
contains "$RUNBOOK" "$REVISION"
contains "$RUNBOOK" 'PREFIX_CACHE'
contains "$RUNBOOK" '400 W'
contains "$RUNBOOK" 'TP2'
contains "$RUNBOOK" 'ds41-1017-maya-exl35'

echo "GLM-5.3 v16 Hyperflare TP2 contract: PASS"
