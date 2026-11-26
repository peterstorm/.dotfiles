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
  glm53-flash-hyperflare-tp2-uncensored
  qwen38-27b-blackfrost-abliterated-bf16-vllm
  ds41-1017-maya-exl35
  ds41-1017-native
  glm53-native
)

# Running + waiting requests from one bridge's /metrics (series prefixed
# PREFIX); status 1 when the bridge does not answer OR answers without the
# expected series: a bridge 200 whose body carries neither gauge must not sum
# to a verified 0, or a renamed series would read as an idle engine while
# requests wait (the fail-open the engine-metrics path refuses).
_inference_bridge_inflight() {
  local url="$1" prefix="$2" text
  text="$(curl -fsS --connect-timeout 2 --max-time 5 "$url" 2>/dev/null)" || return 1
  awk -v pattern="^${prefix}requests_(running|waiting)[{]" \
    '$0 ~ pattern { seen = 1; sum += $NF } END { if (!seen) exit 2; print sum + 0 }' <<<"$text"
}

# In-flight (running + waiting) requests on whatever owns :8000, read from the
# one source that runtime exposes without a key: the ds4-native bridge (:8010),
# the Hyperflare bridge (:8011), or vLLM/SGLang's own /metrics. An unknown
# runtime fails closed (status 1) rather than being treated as idle.
# A model-labelled bridge answers only while its own engine owns :8000
# (503 otherwise), so the first one that answers names the runtime.
# The engine's own metrics must expose BOTH gauges of their family: summing a
# running series whose waiting series vanished would read as idle while requests
# wait, which is a fail-open. switch-ds4-flash-vision-karmic-kraken-v1.sh
# carried that check by itself until the gates were consolidated here.
inference_active_requests() {
  local text
  _inference_bridge_inflight http://127.0.0.1:8010/metrics 'ds4:' && return 0
  _inference_bridge_inflight http://127.0.0.1:8011/metrics 'hyperflare:' && return 0
  text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/metrics)" || return 1
  if grep -q '^vllm:num_requests_running{' <<<"$text"; then
    grep -q '^vllm:num_requests_waiting{' <<<"$text" || return 1
    awk '/^vllm:num_requests_(running|waiting)\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
    return 0
  fi
  if grep -q '^sglang:num_running_reqs{' <<<"$text"; then
    grep -q '^sglang:num_queue_reqs{' <<<"$text" || return 1
    awk '/^sglang:num_(running|queue)_reqs\{/ {sum += $NF} END {print sum + 0}' <<<"$text"
    return 0
  fi
  return 1
}

# The runtime that owns :8000, named for a refusal: the first bridge that
# answers (a model-labelled bridge answers only while its own engine owns the
# port), else the metrics family the engine exposes. An unrecognised answer is
# "an unknown runtime", never silence.
inference_active_runtime() {
  local text
  if _inference_bridge_inflight http://127.0.0.1:8010/metrics 'ds4:' >/dev/null; then echo ds4-native; return 0; fi
  if _inference_bridge_inflight http://127.0.0.1:8011/metrics 'hyperflare:' >/dev/null; then echo hyperflare; return 0; fi
  if ! text="$(curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/metrics 2>/dev/null)"; then
    echo "an unknown runtime"
    return 0
  fi
  if grep -q '^vllm:num_requests_running{' <<<"$text"; then echo vllm; return 0; fi
  if grep -q '^sglang:num_running_reqs{' <<<"$text"; then echo sglang; return 0; fi
  echo "an unknown runtime"
}

# Who holds the engine, as far as the serving host can prove: the runtime, and
# the peers connected to :8000. A cutover runs on the serving host, so it sees
# its clients' addresses and never their PIDs (a PID lives on the client's
# machine); naming an address is honest, inventing a process is not. Best
# effort throughout: attribution explains a refusal, it never becomes one.
inference_inflight_attribution() {
  local runtime peers
  runtime="$(inference_active_runtime)"
  peers="$(ss -Htn state established '( sport = :8000 )' 2>/dev/null \
    | awk '{print $NF}' | sed 's/:[^:]*$//' | sort -u | paste -sd, -)" || peers=""
  printf '%s; peers connected to :8000: %s' "$runtime" "${peers:-unknown}"
}

# How long a cutover waits for the engine to drain, how far apart it samples,
# and how many consecutive idle samples prove the drain.
# The gate used to sample at a fixed 0/3/3 and refuse on the FIRST busy sample,
# so one request in flight -- a bursty client, or a single long reasoning turn --
# failed a cutover that had nothing else running (2026-11-26: refused three times
# with one request in flight, then passed with the same clients still connected).
# Waiting is bounded; giving up is still a refusal.
INFERENCE_IDLE_SAMPLE_SECONDS="${INFERENCE_IDLE_SAMPLE_SECONDS:-2}"
INFERENCE_IDLE_STREAK="${INFERENCE_IDLE_STREAK:-3}"
INFERENCE_IDLE_WAIT_SECONDS="${INFERENCE_IDLE_WAIT_SECONDS:-60}"

# Refuse a cutover unless :8000 reports zero in-flight requests
# INFERENCE_IDLE_STREAK times in a row, each sample INFERENCE_IDLE_SAMPLE_SECONDS
# apart and all within INFERENCE_IDLE_WAIT_SECONDS. A busy sample restarts the
# streak; an unreadable reading is refused at once, so an unknown runtime is
# never treated as idle and never drains a budget it cannot observe.
inference_require_idle_endpoint() {
  local deadline=$((SECONDS + INFERENCE_IDLE_WAIT_SECONDS)) streak=0 active busy=0
  while :; do
    if ! active="$(inference_active_requests)"; then
      echo "error: cannot read in-flight requests of the active profile; refusing cutover" >&2
      return 1
    fi
    if [ "$active" = 0 ]; then
      streak=$((streak + 1))
      busy=0
      if [ "$streak" -ge "$INFERENCE_IDLE_STREAK" ]; then
        echo "IDLE GATE: no running or waiting requests across $streak samples"
        return 0
      fi
    else
      streak=0
      busy="$active"
    fi
    if ((SECONDS >= deadline)); then
      if [ "$busy" != 0 ]; then
        echo "error: $busy request(s) still running or waiting after ${INFERENCE_IDLE_WAIT_SECONDS} s on $(inference_inflight_attribution); refusing cutover" >&2
      else
        echo "error: the engine did not stay idle across ${INFERENCE_IDLE_STREAK} samples within ${INFERENCE_IDLE_WAIT_SECONDS} s; refusing cutover" >&2
      fi
      return 1
    fi
    sleep "$INFERENCE_IDLE_SAMPLE_SECONDS"
  done
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
