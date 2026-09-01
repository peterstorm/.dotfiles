#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/scripts/inference/qwen38/build-qwen38-flash-next-vllm-v2-image.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-flash-next-vllm-v2-image.sh"
OVERLAY="$ROOT/scripts/inference/qwen38/flash-next-v2-safe"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-flash-next-fp8-vllm-v2.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-flash-next-profile-v2.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PLAN="$ROOT/docs/runbooks/qwen38-flash-next-v2-safety-plan-2026-08-30.md"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || {
    echo "FAIL: $file lacks $text" >&2
    exit 1
  }
}

for file in "$BUILD" "$PULL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done

[ "$(sha256sum "$OVERLAY/qwen38-v2-ple-uva.patch" | cut -d' ' -f1)" = 009d4acd2f3b96dd1b2e63b085855ad885e1d2832c0d6eb96d0e0ef4118b90b3 ]
[ "$(sha256sum "$OVERLAY/qwen38-v2-exact-persistent-topk.patch" | cut -d' ' -f1)" = 8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395 ]
[ "$(sha256sum "$OVERLAY/qwen38-v2-accepted-state-safety.patch" | cut -d' ' -f1)" = db95c8dc58cf8ae7b89f61e7194649dab52eacc07cac447cb84bcf8404062ba8 ]
[ "$(sha256sum "$OVERLAY/qwen38-v2-qsa-canonical-order.patch" | cut -d' ' -f1)" = fca4f69894c8583665e9b0758f92ef661b6de68ed550c804588c485fc28159d3 ]
[ "$(sha256sum "$OVERLAY/qwen38-v2-ple-state-safety.patch" | cut -d' ' -f1)" = 653469b47e8e1eec7e45cf0aa1090796d78fb45c43ab91084bf950d18381cc5e ]
[ "$(sha256sum "$OVERLAY/qwen38-v2-large-topk-ties.patch" | cut -d' ' -f1)" = 287c32801f6a7d8700849afad6b0efa03b1885063cdd37864265512fea3414bc ]

contains "$BUILD" 'e126687a9a828d513c01a07cd69f025f27d63280'
contains "$BUILD" '815d965f7ccddd6a2b2da072a4a492115fc3a7e1'
contains "$BUILD" 'c0ac28980016af357df50359d301648352eebbf2'
contains "$BUILD" 'patch --dry-run --batch --fuzz=0'
contains "$BUILD" 'patch --batch --fuzz=0'
contains "$BUILD" 'git -C "$worktree" status --short'
contains "$BUILD" 'pytorch/manylinux2_28-builder:cuda13.0-78e737ad29420ffc4800e677c51e2a852caf8359@sha256:c8d8dba2124931732d1b073dec1d8999cd4d6c5ff7c5e77232137e77d9f00f6a'
contains "$BUILD" 'nvidia/cuda:13.0.3-base-ubuntu24.04@sha256:7c7413a56200486f71f181cad9310f6fd31b6bb21816ade15fc9c1e1e927a5c1'
contains "$BUILD" 'torch_cuda_arch_list=12.0'
contains "$BUILD" 'Dockerfile.topk-rebuild'
contains "$BUILD" 'c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95'
contains "$BUILD" 'rewrite-timestamp=true'
contains "$BUILD" 'vllm-project/vllm#54371@905219234b0698b1f1ec2ed756de7051b080fb1c'
contains "$BUILD" 'vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3'
contains "$BUILD" 'vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f'
contains "$PULL" 'IMAGE_ID="sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1"'
contains "$PULL" 'docker run --rm -i --entrypoint python3'
contains "$PULL" 'VLLM_PLE_CPU_OFFLOAD=1'
contains "$PULL" 'accepted-count-and-state-row-fail-closed'
contains "$PULL" 'deterministic-global-token-index'
contains "$PULL" 'c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95'
contains "$PULL" 'ascending-compressed-block-index'
contains "$PULL" 'prefix_caching=disabled'

if grep -Fq 'scripts/inference/glm53/' "$BUILD" "$OVERLAY/Dockerfile" "$OVERLAY/Dockerfile.topk-rebuild"; then
  echo 'FAIL: Qwen v2 build must not depend on a GLM-owned path' >&2
  exit 1
fi

contains "$OVERLAY/Dockerfile" 'ENV VLLM_PLE_CPU_OFFLOAD=1'
contains "$OVERLAY/Dockerfile" 'ple-state-bounds="accepted-count-and-state-row-fail-closed"'
contains "$OVERLAY/Dockerfile" 'large-topk-ties="deterministic-global-token-index"'
contains "$OVERLAY/Dockerfile.topk-rebuild" 'cmake --build /tmp/vllm-cmake --target _C_stable_libtorch'
contains "$OVERLAY/Dockerfile" 'prefix-cache="disabled-until-equivalence-qualified"'
contains "$OVERLAY/verify.py" 'for rows in (1, 32, 64, 192, 512):'
contains "$OVERLAY/verify.py" 'COLUMNS = 65_536'
contains "$OVERLAY/verify.py" 'expected_ties'
contains "$OVERLAY/verify.py" 'torch.cuda.CUDAGraph()'
contains "$OVERLAY/verify.py" '_build_mixed_token_indices_cpu'
contains "$OVERLAY/verify.py" 'causal_conv1d_update'
contains "$OVERLAY/verify.py" 'selective_state_update'
contains "$OVERLAY/verify.py" 'fused_recurrent_gated_delta_rule'
contains "$OVERLAY/verify.py" 'fused_sigmoid_gating_delta_rule_update'
contains "$OVERLAY/verify.py" '_short_conv_dilated_spec_batched'

contains "$RUN" 'IMAGE="sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1"'
contains "$RUN" 'NAME="qwen38-flash-next-fp8-vllm-v2"'
contains "$RUN" '--restart no'
contains "$RUN" '-e VLLM_PLE_CPU_OFFLOAD=1'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--ngram-parallel-size 2'
contains "$RUN" '--no-enable-prefix-caching'
if grep -Fq -- '--mamba-cache-mode' "$RUN"; then
  echo 'FAIL: prefix-cache-off profile must use the engine effective Mamba mode' >&2
  exit 1
fi
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3}'\'''
contains "$RUN" '--limit-mm-per-prompt '\''{"image":1,"video":0}'\'''
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="qwen38-flash-next-fp8-vllm-v2"'
contains "$SWITCH" 'verify_candidate_image'
contains "$SWITCH" '/opt/qwen38-v2/verify.py'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'Candidate remains restart=no pending full qualification.'
contains "$CATALOG" 'qwen38-flash-next-fp8-vllm-v2'
contains "$PLAN" 'prefix caching remains disabled'

set +e
output="$(MAX_NUM_SEQS=5 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_NUM_SEQS=5 status=$status" >&2; exit 1; }
grep -Fq 'MAX_NUM_SEQS must be an integer in [1, 4]' <<<"$output"

echo 'PASS: Qwen3.8 Flash-Next v2 is source-pinned, exact-top-k, state-bounded, UVA-PLE, rollback-safe, and prefix-cache-off'
