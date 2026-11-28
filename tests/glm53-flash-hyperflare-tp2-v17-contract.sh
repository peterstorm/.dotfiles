#!/usr/bin/env bash
# Static release contract for the GLM-5.3 v17 Hyperflare TP2 test profile.
#
# v17 serves v16's checkpoint (nvidia/GLM-5.3-Flash-FP4-Local) through upstream
# NVIDIA Hyperflare with hyperflare-recipes PR #55 (row-sharded prefill) and
# FlashInfer PR #151 (its kernels), in two prefill modes (rowshard, baseline).
# The contract proves, without Docker or a GPU, that every source is pinned once
# (glm53-v17-hyperflare/pins.sh) and checked by label everywhere it is used,
# that the image re-locks the recipes onto those pins and verifies the result,
# that export and run fail closed on the receipt, the signing key and the
# workstation, that v17 shares v16's switch transaction and gates rather than
# copying them, and that it stays a test profile: in the catalog the switchers
# stop, never in the variant table, switch-primary or Pi's catalog.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
OVERLAY="$GLM/glm53-v17-hyperflare"
PINS="$OVERLAY/pins.sh"
DOCKERFILE="$OVERLAY/Dockerfile"
BUILD="$GLM/build-glm53-flash-hyperflare-tp2-v17-image.sh"
EXPORT="$GLM/export-glm53-flash-hyperflare-tp2-v17.sh"
RUN="$GLM/run-glm53-flash-hyperflare-tp2-v17.sh"
SWITCH="$GLM/switch-glm53-hyperflare-tp2-v17.sh"
SWITCH_LIB="$GLM/hyperflare-switch.sh"
WORKSTATION="$GLM/hyperflare-workstation.sh"
V16_RUN="$GLM/run-glm53-flash-hyperflare-tp2-v16.sh"
V16_DL="$GLM/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
RUNBOOK="$ROOT/scripts/inference/runbooks/glm53-flash-hyperflare-tp2-v17-runbook-2026-11-27.md"
BRIDGE="$ROOT/scripts/inference/shared/hyperflare-metrics.py"

HFI="c99358879813f22557ac619044af514fafacecc6"
HFI_STALE_LOCK="5adb27f259d340231c384ed668bd68e2abc313c5"
HFR="71c9830c5720e19bc6bb6b53c028810edc09fab0"
FI="6d2f90c8670691c168d762cda294dcf2f4eb6dc6"
CONTAINER="glm53-flash-hyperflare-tp2-v17"
SERVED_MODEL="glm-5.3-flash-hyperflare-tp2-v17"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "${1#"$ROOT"/} is missing: $2"; }
absent() { ! grep -Fq -- "$2" "$1" || fail "${1#"$ROOT"/} must not contain: $2"; }

for file in "$PINS" "$DOCKERFILE" "$BUILD" "$EXPORT" "$RUN" "$SWITCH" "$SWITCH_LIB" "$WORKSTATION" "$RUNBOOK"; do
  [ -f "$file" ] || fail "missing ${file#"$ROOT"/}"
done
for script in "$BUILD" "$EXPORT" "$RUN" "$SWITCH"; do
  [ -x "$script" ] || fail "${script#"$ROOT"/} is not executable"
  bash -n "$script"
done
for lib in "$PINS" "$SWITCH_LIB" "$WORKSTATION"; do bash -n "$lib"; done

# --- one place for every pin ---------------------------------------------------------
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$PINS"
[ "$V17_HYPERFLARE_INFERENCE_COMMIT" = "$HFI" ] || fail "hyperflare-inference pin drifted from $HFI"
[ "$V17_RECIPES_COMMIT" = "$HFR" ] || fail "hyperflare-recipes pin drifted from PR #55's head $HFR"
[ "$V17_FLASHINFER_COMMIT" = "$FI" ] || fail "flashinfer pin drifted from PR #151's head $FI"
[ "$V17_RECIPES_LOCKED_HYPERFLARE_INFERENCE_COMMIT" = "$HFI_STALE_LOCK" ] || fail "the recorded stale lock commit drifted"
[ "$V17_CONTAINER" = "$CONTAINER" ] || fail "container drifted from $CONTAINER"
[ "$V17_SERVED_MODEL" = "$SERVED_MODEL" ] || fail "served id drifted from $SERVED_MODEL"
[ "$V17_MODEL" = glm53-fp4-local ] || fail "v17 must export v16's checkpoint directory glm53-fp4-local"
[ "$V17_CHECKPOINT" = "nvidia/GLM-5.3-Flash-FP4-Local@76348ddb2be2e35e39ecfc00e75dc07703f4f3d5" ] ||
  fail "v17's checkpoint must be v16's pinned revision"
contains "$V16_DL" 'REV="76348ddb2be2e35e39ecfc00e75dc07703f4f3d5"'
# The signing key v17 pins is the one v16 pins (the export seeds v16's key).
contains "$V16_RUN" "SIGNING_KEY_FINGERPRINT=\"$V17_SIGNING_KEY_FINGERPRINT\""
# No script carries its own copy of a commit: the pins file is the only home.
for script in "$DOCKERFILE" "$BUILD" "$EXPORT" "$RUN" "$SWITCH"; do
  for pin in "$HFI" "$HFR" "$FI"; do absent "$script" "$pin"; done
  absent "$script" "${HFI:0:8}"
done
bash "$ROOT/tests/glm53-v17-hyperflare-unit.sh" >/dev/null || fail "pins.sh failed its unit tests"

# --- image ---------------------------------------------------------------------------
grep -Eq '^FROM nvidia/cuda:13\.1\.1-devel-ubuntu24\.04@sha256:[0-9a-f]{64}$' "$DOCKERFILE" ||
  fail "CUDA base image is not digest-pinned 13.1.1-devel"
grep -Eq '^FROM ghcr\.io/astral-sh/uv:0\.11\.29@sha256:[0-9a-f]{64} AS uv$' "$DOCKERFILE" ||
  fail "uv image is not digest-pinned 0.11.29"
grep -Eq '^ARG RUSTUP_INIT_SHA256=[0-9a-f]{64}$' "$DOCKERFILE" || fail "rustup-init is not sha256-pinned"
contains "$DOCKERFILE" 'echo "$RUSTUP_INIT_SHA256  /tmp/rustup-init" | sha256sum -c -'
absent "$DOCKERFILE" 'sh.rustup.rs'
# The three sources are required build arguments with no default to fall back on.
for arg in HYPERFLARE_INFERENCE_COMMIT RECIPES_COMMIT FLASHINFER_COMMIT; do
  grep -Eq "^ARG $arg\$" "$DOCKERFILE" || fail "ARG $arg must be declared without a default"
  contains "$BUILD" "--build-arg \"$arg=\$V17_"
done
contains "$DOCKERFILE" "grep -Eqx '[0-9a-f]{40}'"
contains "$DOCKERFILE" 'test "$(git rev-parse HEAD)" = "$HYPERFLARE_INFERENCE_COMMIT"'
contains "$DOCKERFILE" 'test "$(git rev-parse HEAD)" = "$RECIPES_COMMIT"'
contains "$DOCKERFILE" 'cargo build --locked --release'
contains "$DOCKERFILE" 'uv sync --locked --extra test'
# The re-lock: ignition's root source onto the exact rev; flashinfer-python, which
# arrives transitively through ignition[prepare] (whose own source names main), by a
# uv override, the only declaration that reaches a transitive requirement. Every
# lock source is asserted and the version moves are recorded.
contains "$DOCKERFILE" 'rev = "'"'"'"$HYPERFLARE_INFERENCE_COMMIT"'"'"'" }'
contains "$DOCKERFILE" 'override-dependencies = ['
contains "$DOCKERFILE" '"flashinfer-python[b12x] @ git+https://github.com/local-inference-lab/flashinfer.git@%s",'
contains "$DOCKERFILE" "! grep -q '^flashinfer-python = ' pyproject.toml"
contains "$DOCKERFILE" 'hyperflare-inference.git?subdirectory=heliopause&rev=$HYPERFLARE_INFERENCE_COMMIT#$HYPERFLARE_INFERENCE_COMMIT'
contains "$DOCKERFILE" 'flashinfer.git?rev=$FLASHINFER_COMMIT#$FLASHINFER_COMMIT'
contains "$DOCKERFILE" '> relock.diff'
# The installed sources are the PRs': PR #151's kernels import, PR #55's parameters exist.
contains "$DOCKERFILE" 'k.segment_summarize; k.segment_finalize'
contains "$DOCKERFILE" "{'row_shard_prefill', 'row_shard_attention'} <= f"
# Build caches never land in a layer (desktop's pool is nearly full).
contains "$DOCKERFILE" '--mount=type=tmpfs,target=/tmp/uv-cache'
contains "$DOCKERFILE" '--mount=type=tmpfs,target=/tmp/cargo-target'
contains "$BUILD" 'MIN_FREE_GIB="${MIN_FREE_GIB:-30}"'
# flare (Rust) finds its store via getpwuid, the exporter (Python) via $HOME.
contains "$DOCKERFILE" 'usermod -d /flare-home ubuntu'
contains "$DOCKERFILE" 'liburing-dev ninja-build'
for label in hyperflare-commit recipes-commit flashinfer-commit; do
  contains "$DOCKERFILE" "ai.peterstorm.inference.$label=\$"
done
for script in "$BUILD" "$EXPORT" "$RUN"; do
  contains "$script" 'source "$SCRIPT_DIR/glm53-v17-hyperflare/pins.sh"'
  contains "$script" 'v17_image_matches_pins "$labels"'
done

# --- export --------------------------------------------------------------------------
contains "$EXPORT" 'PREFILL="$(v17_resolve_prefill "${PREFILL:-rowshard}")" || exit 2'
contains "$EXPORT" 'mapfile -t PREFILL_FLAGS < <(v17_prefill_flags "$PREFILL")'
contains "$EXPORT" '--prefill-chunk-size "$CHUNK" --mtp-draft-tokens 5 --mtp-only'
contains "$EXPORT" '--gpus 0,1 --max-concurrency "$CONC"'
contains "$EXPORT" 'CONC="${CONC:-8}"'
contains "$EXPORT" 'ROOT_HOST="$CKPT_ROOT" "$SCRIPT_DIR/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh" --verify'
contains "$EXPORT" '-v "$CKPT_HOST:/ckpt/$V17_MODEL:ro"'
contains "$EXPORT" '-e HOME=/flare-home -e HF_HUB_OFFLINE=1'
contains "$EXPORT" '--security-opt seccomp=unconfined'
contains "$EXPORT" '[ "$(id -u)" = 1000 ]'
[ "$V17_DEFAULT_ROOT" = /models/glm53-hyperflare-v17 ] || fail "the default state root drifted"
for script in "$EXPORT" "$RUN"; do contains "$script" 'V17_ROOT="${V17_ROOT:-$V17_DEFAULT_ROOT}"'; done
absent "$EXPORT" 'FLARE_HOME="/models/glm53-hyperflare/flare-home"'
contains "$EXPORT" 'CORE_RECEIPT="$V17_ROOT/core-$PREFILL.txt"'
contains "$EXPORT" 'entry="$(v17_entry_from_export_log "$V17_MODEL" <"$LOG")"'
contains "$EXPORT" 'install -m 600 "$SIGNING_KEY_SOURCE/$file" "$key_dir/$file"'
contains "$EXPORT" 'cmp -s "$key_dir/development-signing-key.pem" "$SIGNING_KEY_SOURCE/development-signing-key.pem"'
contains "$EXPORT" 'a GPU has ${mib// /} MiB in use'

# --- run -----------------------------------------------------------------------------
contains "$RUN" 'source "$SCRIPT_DIR/hyperflare-workstation.sh"'
contains "$RUN" 'hyperflare_require_workstation "$SCRIPT_DIR" || exit 1'
contains "$RUN" 'hyperflare_require_free_endpoint || exit 1'
contains "$RUN" 'CORE="$(v17_receipt_core "$V17_MODEL" "$PREFILL" <"$CORE_RECEIPT")"'
contains "$RUN" '--dangerously-approve-key "$V17_SIGNING_KEY_FINGERPRINT"'
contains "$RUN" '--dangerously-accept-publisher local-development'
contains "$RUN" '--gpus 0,1 --host 0.0.0.0 --port 8000'
contains "$RUN" '--served-model-name "$V17_SERVED_MODEL"'
contains "$RUN" '--prefix-cache-memory "$PREFIX_CACHE" --mtp-draft-tokens 5'
contains "$RUN" 'PREFIX_CACHE="${PREFIX_CACHE:-16G}"'
# Upstream has balanced and throughput; interactive (the TTFT guard) is the fork's.
contains "$RUN" 'SCHEDULER="${SCHEDULER:-balanced}"'
contains "$RUN" '  balanced | throughput) ;;'
absent "$RUN" 'interactive)'
contains "$RUN" '--api-key-file /run/inference/api-key'
contains "$RUN" '-v "$KEYFILE:/run/inference/api-key:ro"'
contains "$RUN" '--restart no'
contains "$RUN" '--security-opt seccomp=unconfined'
contains "$RUN" '--label ai.peterstorm.inference.prefill="$PREFILL"'
contains "$RUN" '--label ai.peterstorm.inference.package="$CORE"'
contains "$RUN" '--entrypoint /usr/local/bin/flare'
absent "$RUN" 'VLLM_API_KEY=$VLLM_API_KEY'

# --- switch: v16's transaction, not a copy ---------------------------------------------
contains "$SWITCH" 'source "$SCRIPT_DIR/hyperflare-switch.sh"'
contains "$SWITCH" 'TARGET="$V17_CONTAINER"'
contains "$SWITCH" 'EXPECTED_MODEL="$V17_SERVED_MODEL"'
contains "$SWITCH" 'RUN="$SCRIPT_DIR/run-glm53-flash-hyperflare-tp2-v17.sh"'
contains "$SWITCH" 'export PREFILL'
contains "$SWITCH" 'hyperflare_switch_main'
absent "$SWITCH" 'generation_verdict()'
contains "$SWITCH_LIB" 'if ! wait_for_target || ! require_generation || ! require_metrics_bridge'

# --- a test profile: catalogued, never a primary ---------------------------------------
contains "$CATALOG" "  $CONTAINER"
# The stop-and-export driver's scope (glm53-flash-hyperflare-tp2-*) covers it.
[[ "$CONTAINER" == glm53-flash-hyperflare-tp2-* ]] || fail "$CONTAINER is outside the export driver's scope"
# shellcheck source=scripts/inference/glm53/hyperflare-variants.sh
source "$GLM/hyperflare-variants.sh"
! hyperflare_variant_model v17 >/dev/null 2>&1 || fail "v17 is a runtime profile, not a checkpoint variant"
absent "$ROOT/scripts/inference/switch-primary.sh" "$CONTAINER"
# shellcheck source=tests/lib/pi-catalog.sh
source "$ROOT/tests/lib/pi-catalog.sh"
assert_not_in_pi_catalog "$SERVED_MODEL"

# --- monitoring: the bridge reads only series upstream Helios still exports ------------
contains "$BRIDGE" 'flare_prefill_tokens_total'

# --- runbook ---------------------------------------------------------------------------
for fact in "$HFI" "$HFR" "$FI" "$HFI_STALE_LOCK" 'PR #55' 'PR #151' 'rowshard' 'baseline' \
            'V17_ROOT' 'NVMe' 'interactive' 'switch-primary.sh' 'probe-hyperflare-throughput.py'; do
  contains "$RUNBOOK" "$fact"
done

echo "GLM-5.3 v17 Hyperflare TP2 contract: PASS"
