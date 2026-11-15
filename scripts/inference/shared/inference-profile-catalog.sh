#!/usr/bin/env bash
# Repository-owned GPU profile facts and fail-closed Docker operations.

INFERENCE_PROFILE_CONTAINERS=(
  ds4-0731-r31
  ds4-0731-r33
  ds4-infernal-invocation-cu133-r18
  ds4-flash-vision-infernal-invocation-cu133-r21-v1
  ds4-flash-vision-karmic-kraken-v1
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
  qwen38-flash-next-fp8-vllm-v2
  glm53-flash-exl3-k4-vllm-sm120-v10
  glm53-flash-exl3-k4-vllm-sm120-v11
  glm53-flash-exl3-k4-vllm-sm120-v11.1
  glm53-flash-exl3-k4-vllm-sm120-v12
  glm53-flash-exl3-k4-vllm-sm120-v13
  glm53-flash-spark-tp2-v14
  glm53-flash-qad2-tp2-v15
  glm53-flash-hyperflare-tp2-v16
  glm53-flash-hyperflare-tp2-cyber-hybrid
  glm53-flash-hyperflare-tp2-cyber-hybrid-bf16
  glm53-flash-hyperflare-tp2-uncensored
  qwen38-27b-blackfrost-abliterated-bf16-vllm
  ds41-1017-maya-exl35
  ds41-1017-native
)

# Running + waiting requests from one bridge's /metrics (series prefixed
# PREFIX); status 1 when the bridge does not answer.
_inference_bridge_inflight() {
  local url="$1" prefix="$2" text
  text="$(curl -fsS --connect-timeout 2 --max-time 5 "$url" 2>/dev/null)" || return 1
  awk -v pattern="^${prefix}requests_(running|waiting)[{]" '$0 ~ pattern {sum += $NF} END {print sum + 0}' <<<"$text"
}

# In-flight (running + waiting) requests on whatever owns :8000, read from the
# one source that runtime exposes without a key: the ds4-native bridge (:8010),
# the Hyperflare bridge (:8011), or vLLM/SGLang's own /metrics. An unknown
# runtime fails closed (status 1) rather than being treated as idle.
# A model-labelled bridge answers only while its own engine owns :8000
# (503 otherwise), so the first one that answers names the runtime.
inference_active_requests() {
  local text
  _inference_bridge_inflight http://127.0.0.1:8010/metrics 'ds4:' && return 0
  _inference_bridge_inflight http://127.0.0.1:8011/metrics 'hyperflare:' && return 0
  text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/metrics)" || return 1
  grep -Eq '^(vllm:num_requests_running|sglang:num_running_reqs)\{' <<<"$text" || return 1
  awk '/^(vllm:num_requests_(running|waiting)|sglang:num_(running|queue)_reqs)\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
}

# Refuse a cutover unless :8000 reports zero in-flight requests three times
# over ~6 s (a request arriving between samples is caught by the next one).
inference_require_idle_endpoint() {
  local delay active
  for delay in 0 3 3; do
    sleep "$delay"
    active="$(inference_active_requests)" || {
      echo "error: cannot read in-flight requests of the active profile; refusing cutover" >&2
      return 1
    }
    if [ "$active" != 0 ]; then
      echo "error: $active request(s) are running or waiting; refusing cutover" >&2
      return 1
    fi
  done
  echo "IDLE GATE: no running or waiting requests across three samples"
}

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
