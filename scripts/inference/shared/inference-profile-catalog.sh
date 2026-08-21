#!/usr/bin/env bash
# Repository-owned GPU profile facts and fail-closed Docker operations.

INFERENCE_PROFILE_CONTAINERS=(
  ds4-0731-r31
  ds4-0731-r33
  qwen38-27b-bf16
  qwen38-27b-bf16-dspark-vllm-v2
  qwen38-27b-bf16-dspark-sglang-v2
  qwen38-27b-bf16-dspark-vllm
  qwen38-27b-bf16-dspark-sglang
  qwen38-27b-bf16-dflash2-sglang
  qwen38-27b-bf16-dflash2-sglang-native
  qwen38-27b-bf16-dflash2-vllm
  muse-glimmer-30b-bf16-dflash
  muse-glimmer-30b-abliterated-bf16-dflash
)

inference_profile_containers_except() {
  local excluded="${1:-}" container
  for container in "${INFERENCE_PROFILE_CONTAINERS[@]}"; do
    [ "$container" = "$excluded" ] || printf '%s\n' "$container"
  done
}

inference_require_pinned_checkpoint() {
  local directory="$1" expected="$2" hint="$3"
  if [ ! -f "$directory/config.json" ] || [ ! -f "$directory/.download-complete" ]; then
    echo "error: pinned checkpoint is incomplete at $directory" >&2
    echo "       $hint" >&2
    return 1
  fi
  if ! grep -Fxq "$expected" "$directory/.download-complete"; then
    echo "error: checkpoint marker at $directory does not match $expected" >&2
    return 1
  fi
}

inference_container_exists() {
  local container="$1" output status
  if output="$(docker inspect "$container" 2>&1)"; then
    return 0
  else
    status=$?
  fi
  if grep -Fqi 'No such object' <<<"$output" || grep -Fqi 'No such container' <<<"$output"; then
    return 1
  fi
  echo "error: could not inspect container '$container' (status $status): $output" >&2
  return 2
}

inference_stop_container_if_present() {
  local container="$1" exists_status=0
  inference_container_exists "$container" || exists_status=$?
  case "$exists_status" in
    0)
      docker stop -t 30 "$container" >/dev/null || {
        echo "error: failed to stop container '$container'" >&2
        return 1
      }
      ;;
    1) ;;
    *) return "$exists_status" ;;
  esac
}

inference_remove_container_if_present() {
  local container="$1" exists_status=0
  inference_container_exists "$container" || exists_status=$?
  case "$exists_status" in
    0)
      docker rm -f "$container" >/dev/null || {
        echo "error: failed to remove container '$container'" >&2
        return 1
      }
      ;;
    1) ;;
    *) return "$exists_status" ;;
  esac
}
