#!/usr/bin/env bash
# Pure catalog for the Loom planning + implementation benchmark.
#
# Arm records are tab-delimited and contain, in order:
#   Pi model selector, served model id, context window, profile container,
#   attended startup hint, human-readable profile label.
#
# Keep this module side-effect free: callers decide whether to probe, switch,
# or launch anything.

BENCHMARK_ARM_IDS=(ds4 qwen glm-dflash glm-mtp)
BENCHMARK_PROTOCOL_FILES=(
  frozen/brief.md
  frozen/ui-relay-types.ts
  frozen/answer-key.md
  hidden/reference-spec.md
  hidden/ui-relay.hidden.test.ts
  rubric.md
)

benchmark_arm_ids() {
  printf '%s\n' "${BENCHMARK_ARM_IDS[@]}"
}

benchmark_protocol_files() {
  printf '%s\n' "${BENCHMARK_PROTOCOL_FILES[@]}"
}

benchmark_arm_record() {
  case "${1:-}" in
    ds4)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        'desktop-vllm/deepseek-v4-flash:max' \
        'deepseek-v4-flash' \
        '1048576' \
        'ds4-infernal-invocation-cu133-r18' \
        'bash ~/.dotfiles/scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh' \
        'DeepSeek V4 Flash r18'
      ;;
    qwen)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        'desktop-vllm/qwen3.8-27b:xhigh' \
        'qwen3.8-27b' \
        '262144' \
        'qwen38-27b-bf16-dspark-sglang-v2' \
        'bash ~/.dotfiles/scripts/inference/qwen38/switch-qwen38-backend-v4.sh sglang' \
        'Qwen3.8-27B BF16 DSpark'
      ;;
    glm-dflash)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        'desktop-vllm/glm-5.3-flash-exl3-k4-vision:max' \
        'glm-5.3-flash-exl3-k4-vision' \
        '98304' \
        'glm53-flash-exl3-k4-vllm-sm120-v3' \
        'bash ~/.dotfiles/scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh start' \
        'GLM-5.3 Flash EXL3 K4 v84 Vision + DFlash2 K7'
      ;;
    glm-mtp)
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        'desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max' \
        'glm-5.3-flash-exl3-k4-vision-mtp-384k' \
        '393216' \
        'glm53-flash-exl3-k4-vllm-sm120-v5' \
        'bash ~/.dotfiles/scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start' \
        'GLM-5.3 Flash EXL3 K4 v84 Vision + MTP3 384K'
      ;;
    *)
      printf 'unknown arm: %s (expected one of: %s)\n' \
        "${1:-<empty>}" "${BENCHMARK_ARM_IDS[*]}" >&2
      return 2
      ;;
  esac
}
