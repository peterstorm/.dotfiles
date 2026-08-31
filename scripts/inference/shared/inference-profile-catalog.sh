#!/usr/bin/env bash
# Repository-owned GPU profile facts and fail-closed Docker operations.

INFERENCE_PROFILE_CONTAINERS=(
  ds4-0731-r31
  ds4-0731-r33
  ds4-infernal-invocation-cu133-r18
  qwen38-27b-bf16
  qwen38-27b-bf16-dspark-vllm-v2
  qwen38-27b-bf16-dspark-sglang-v2
  qwen38-27b-bf16-dspark-vllm
  qwen38-27b-bf16-dspark-sglang
  qwen38-27b-bf16-dflash2-sglang
  qwen38-27b-bf16-dflash2-sglang-native
  qwen38-27b-bf16-dflash2-sglang-v2
  qwen38-27b-bf16-dflash2-vllm
  qwen38-27b-bf16-dflash2-vllm-v2
  qwen38-27b-bf16-dflash2-vllm-v3
  qwen38-flash-next-fp8-vllm-v1
  glm53-flash-nvfp4-vllm-sm120-v2
  glm53-flash-exl3-k4-vllm-sm120-v1
  glm53-flash-exl3-k4-vllm-sm120-v2
  glm53-flash-exl3-k4-vllm-sm120-v3
  glm53-flash-exl3-k4-vllm-sm120-v4
  glm53-flash-exl3-k4-vllm-sm120-v5
  glm53-flash-exl3-k4-vllm-sm120-v6
  glm53-flash-exl3-k4-vllm-sm120-v7
  glm53-flash-exl3-k4-vllm-sm120-v8
  glm53-flash-exl3-k4-vllm-sm120-v9
  muse-glimmer-30b-bf16-dflash
  muse-glimmer-30b-abliterated-bf16-dflash
)

inference_profile_containers_except() {
  local excluded="${1:-}" container
  for container in "${INFERENCE_PROFILE_CONTAINERS[@]}"; do
    [ "$container" = "$excluded" ] || printf '%s\n' "$container"
  done
}

inference_verify_checkpoint_manifest() {
  local directory="$1" manifest="$2"
  local expected_sha expected_size relative extra file actual_size actual_sha
  while read -r expected_sha expected_size relative extra; do
    [ -n "${relative:-}" ] || continue
    if [ -n "${extra:-}" ] \
      || ! [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] \
      || ! [[ "$expected_size" =~ ^[1-9][0-9]*$ ]] \
      || [[ "$relative" = /* || "$relative" = ".." || "$relative" = ../* \
        || "$relative" = */../* || "$relative" = */.. ]]; then
      echo "error: invalid checkpoint manifest record: $expected_sha $expected_size $relative ${extra:-}" >&2
      return 1
    fi
    file="$directory/$relative"
    if [ ! -f "$file" ]; then
      echo "error: checkpoint artifact is missing: $file" >&2
      return 1
    fi
    actual_size="$(stat -c %s "$file")" || return 1
    if [ "$actual_size" != "$expected_size" ]; then
      echo "error: checkpoint artifact size mismatch: $file (expected $expected_size, got $actual_size)" >&2
      return 1
    fi
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)" || return 1
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "error: checkpoint artifact checksum mismatch: $file" >&2
      return 1
    fi
  done <<<"$manifest"
}

inference_require_pinned_checkpoint() {
  local directory="$1" expected="$2" manifest="$3" hint="$4"
  if [ -z "$manifest" ]; then
    echo "error: checkpoint manifest is empty for $expected" >&2
    return 1
  fi
  if [ ! -f "$directory/config.json" ] || [ ! -f "$directory/.download-complete" ]; then
    echo "error: pinned checkpoint is incomplete at $directory" >&2
    echo "       $hint" >&2
    return 1
  fi
  if ! grep -Fxq "$expected" "$directory/.download-complete"; then
    echo "error: checkpoint marker at $directory does not match $expected" >&2
    return 1
  fi
  inference_verify_checkpoint_manifest "$directory" "$manifest"
}

inference_container_running() {
  local container="$1" output status
  if output="$(docker inspect --format '{{.State.Running}}' "$container" 2>&1)"; then
    case "$output" in
      true) return 0 ;;
      false) return 1 ;;
      *)
        echo "error: invalid running state for container '$container': $output" >&2
        return 2
        ;;
    esac
  else
    status=$?
  fi
  if grep -Fqi 'No such object' <<<"$output" || grep -Fqi 'No such container' <<<"$output"; then
    return 1
  fi
  echo "error: could not inspect running state for container '$container' (status $status): $output" >&2
  return 2
}

inference_require_container_label() {
  local container="$1" label="$2" expected="$3" output status
  if output="$(docker inspect --format "{{ index .Config.Labels \"$label\" }}" "$container" 2>&1)"; then
    if [ "$output" = "$expected" ]; then
      return 0
    fi
    echo "error: container '$container' label '$label' is '$output', expected '$expected'" >&2
    return 1
  else
    status=$?
  fi
  echo "error: could not inspect label '$label' on container '$container' (status $status): $output" >&2
  return 2
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

inference_quiesce_failed_container() {
  local container="$1" cleanup_failed=0
  if ! docker update --restart=no "$container" >/dev/null; then
    echo "error: failed to disable restart policy for $container" >&2
    cleanup_failed=1
  fi
  if ! docker stop -t 30 "$container" >/dev/null; then
    echo "error: failed to stop $container after startup failure" >&2
    cleanup_failed=1
  fi
  if [ "$cleanup_failed" -ne 0 ]; then
    return 70
  fi
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
