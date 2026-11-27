# shellcheck shell=bash
# The transactional start/stop of one Hyperflare GLM-5.3 TP2 profile, shared by
# every Hyperflare switcher (switch-glm53-hyperflare-tp2-v16.sh for the v16 and
# uncensored variants, switch-glm53-hyperflare-tp2-v17.sh for v17). Source it;
# it defines functions only. The switcher that sources it sets what it serves:
#
#   TARGET          the container the run script starts
#   EXPECTED_MODEL  the one id /v1/models must serve
#   RUN             the run script (--preflight, --launch)
#   BOOT_RECEIPT    where an accepted boot's receipt goes
#   PROFILE_LABEL   the profile's short name in messages (v16, uncensored, v17)
#   MODE            status | start | stop
#
# and then calls hyperflare_switch_main. It also needs inference-api-key.sh and
# inference-profile-catalog.sh sourced.
#
# Launch is transactional at restart=no; only a fully accepted boot (healthy,
# authenticated, exact model id, the asked-for word decoded, bridge on :8011
# translating) is promoted to restart=unless-stopped, and a failed one restores
# whatever profile set was running before.

# The package carries compiled kernels and captured graphs; the v16 recipe
# measured ~30 s launch-to-ready at TP2. 15 minutes covers a cold page cache.
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-900}"
GENERATION_TIMEOUT_SECONDS="${GENERATION_TIMEOUT_SECONDS:-180}"

running_profiles() {
  local container status
  for container in "${INFERENCE_PROFILE_CONTAINERS[@]}"; do
    status=0
    inference_container_running "$container" || status=$?
    case "$status" in
      0) printf '%s\n' "$container" ;;
      1) ;;
      *) return "$status" ;;
    esac
  done
}

authenticated_models() {
  local key="$1" escaped_key
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  {
    printf 'url = "http://127.0.0.1:8000/v1/models"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
    printf 'connect-timeout = 2\nmax-time = 10\nfail\n'
  } | curl --silent --show-error --config -
}

wait_for_target() {
  local deadline status key models_json
  deadline=$((SECONDS + STARTUP_TIMEOUT_SECONDS))
  while ((SECONDS < deadline)); do
    status=0
    inference_container_running "$TARGET" || status=$?
    case "$status" in
      0) ;;
      1) echo "error: $TARGET exited during startup" >&2; return 1 ;;
      *) return "$status" ;;
    esac
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health >/dev/null 2>&1; then
      inference_resolve_client_keyfile || {
        echo "error: no synchronized API key exists after launch" >&2
        return 1
      }
      key="$(<"$INFERENCE_CLIENT_KEYFILE")"
      models_json="$(authenticated_models "$key" 2>/dev/null)" || models_json=''
      if jq -e --arg expected "$EXPECTED_MODEL" '
        .data | type == "array" and length == 1 and .[0].id == $expected
      ' <<<"$models_json" >/dev/null 2>&1; then
        echo "HEALTHY + AUTHENTICATED + EXACT MODEL: $TARGET ($EXPECTED_MODEL)"
        return 0
      fi
    fi
    sleep 5
  done
  echo "error: $TARGET did not serve authenticated model $EXPECTED_MODEL within ${STARTUP_TIMEOUT_SECONDS}s" >&2
  return 1
}

# generation_verdict HTTP_CODE BODY -> exactly one line, ok:<tokens> or error:<reason>.
# Pure. Health, /v1/models and the bridge all answer before a single token is
# decoded; on 2026-11-15 the first cyber-hybrid-bf16 package passed all three while
# every request failed with "prepared model reported device error 1" (non-finite
# logits). Only a generated token proves the model serves -- and only the asked-for
# word proves it decodes sense: the second package (donor tensors fetched from a
# shifted range) generated fluent multilingual token salad and passed a token count.
generation_verdict() {
  local code="$1" body="$2" verdict
  if [ "$code" != 200 ]; then
    echo "error:HTTP $code: $(jq -r '.error.message // empty' <<<"$body" 2>/dev/null | head -c 200)"
    return
  fi
  verdict="$(jq -r '
    (.usage.completion_tokens // 0) as $n
    | (.choices[0].message // {}) as $m
    | ([$m.content, $m.reasoning_content] | map(select(type == "string")) | join(" ")) as $text
    | if ($n | type) != "number" or $n < 1 or ($text | test("^\\s*$")) then
        "error:the reply carries no generated tokens"
      elif ($text | test("\\bready\\b"; "i")) then "ok:\($n)"
      else "error:the reply is not the asked-for word (incoherent decode?): \($text | gsub("\\s+"; " ") | .[0:120])"
      end
  ' <<<"$body" 2>/dev/null)" || verdict=""
  echo "${verdict:-error:the reply carries no generated tokens}"
}

# A short, low-effort completion against the exact served id: acceptance fails
# unless the model decodes the asked-for word (v16 answers "ready" in 10-16
# tokens; 64 leaves a longer thinker room). The key reaches curl through its
# stdin config, never argv.
require_generation() {
  local key escaped_key request response code verdict
  inference_resolve_client_keyfile || { echo "error: no synchronized API key for the generation check" >&2; return 1; }
  key="$(<"$INFERENCE_CLIENT_KEYFILE")"
  escaped_key="${key//\\/\\\\}"
  escaped_key="${escaped_key//\"/\\\"}"
  request="$(jq -cn --arg model "$EXPECTED_MODEL" '{model: $model, max_tokens: 64, reasoning_effort: "low",
    messages: [{role: "user", content: "Reply with the single word: ready"}]}')"
  response="$({
    printf 'url = "http://127.0.0.1:8000/v1/chat/completions"\n'
    printf 'header = "Authorization: Bearer %s"\n' "$escaped_key"
    printf 'header = "Content-Type: application/json"\n'
    printf 'connect-timeout = 2\nmax-time = %s\n' "$GENERATION_TIMEOUT_SECONDS"
  } | curl --silent --show-error --config - --data "$request" --write-out '\n%{http_code}')" || {
    echo "error: generation check could not reach :8000" >&2
    return 1
  }
  code="${response##*$'\n'}"
  verdict="$(generation_verdict "$code" "${response%$'\n'*}")"
  case "$verdict" in
    ok:*) echo "GENERATES: $EXPECTED_MODEL decoded ${verdict#ok:} token(s)" ;;
    *) echo "error: $EXPECTED_MODEL does not generate: ${verdict#error:}" >&2; return 1 ;;
  esac
}

# The bridge is part of acceptance: a profile the dashboards and the ledger
# cannot see is not done.
require_metrics_bridge() {
  local text
  text="$(curl -fsS --connect-timeout 2 --max-time 10 http://127.0.0.1:8011/metrics)" || {
    echo "error: Hyperflare metrics bridge on :8011 is not serving (systemctl status hyperflare-metrics)" >&2
    return 1
  }
  grep -Fq "hyperflare:model_info{model_name=\"$EXPECTED_MODEL\"} 1" <<<"$text" || {
    echo "error: bridge on :8011 does not report model $EXPECTED_MODEL" >&2
    return 1
  }
  echo "METRICS BRIDGE: :8011 reports $EXPECTED_MODEL"
}

# Runs with errexit suppressed (it sits in an `if ! … ||` chain), so every step
# is checked explicitly and a failure names the step; success is printed only
# after the receipt is actually in place.
report_boot_receipt() {
  local logs image_id started_at package receipt_dir receipt_tmp capacity_lines
  receipt_failed() { echo "error: boot receipt: $1" >&2; [ -z "${receipt_tmp:-}" ] || rm -f "$receipt_tmp"; return 1; }
  logs="$(docker logs "$TARGET" 2>&1)" || { receipt_failed "docker logs $TARGET failed"; return 1; }
  image_id="$(docker inspect "$TARGET" --format '{{.Image}}')" || { receipt_failed "docker inspect (image) failed"; return 1; }
  started_at="$(docker inspect "$TARGET" --format '{{.State.StartedAt}}')" || { receipt_failed "docker inspect (start time) failed"; return 1; }
  package="$(docker inspect "$TARGET" --format '{{index .Config.Labels "ai.peterstorm.inference.package"}}')" \
    || { receipt_failed "docker inspect (package label) failed"; return 1; }
  # Recipe: "Plan cache. per GPU: 86.56 GiB loaded · 7.71 GiB cache budget" and
  # "Allocate cache. 15.4 GiB · 2231808 KV tokens · ..." at TP2.
  capacity_lines="$(grep -E 'Plan cache\.|Allocate cache\.|Start server\.' <<<"$logs" | tail -n 6 || true)"
  receipt_dir="$(dirname "$BOOT_RECEIPT")"
  install -d -m 700 "$receipt_dir" || { receipt_failed "cannot create $receipt_dir"; return 1; }
  receipt_tmp="$(mktemp "$receipt_dir/.$PROFILE_LABEL-boot-receipt.XXXXXX")" || { receipt_failed "cannot create a temporary file in $receipt_dir"; return 1; }
  {
    printf 'container=%s\nmodel=%s\npackage=%s\nstarted_at=%s\nimage=%s\n' \
      "$TARGET" "$EXPECTED_MODEL" "$package" "$started_at" "$image_id"
    printf '%s\n' '--- capacity lines ---'
    printf '%s\n' "${capacity_lines:-<none captured>}"
  } >"$receipt_tmp" || { receipt_failed "cannot write $receipt_tmp"; return 1; }
  chmod 600 "$receipt_tmp" || { receipt_failed "cannot chmod $receipt_tmp"; return 1; }
  mv -f "$receipt_tmp" "$BOOT_RECEIPT" || { receipt_failed "cannot move the receipt to $BOOT_RECEIPT"; return 1; }
  printf 'BOOT RECEIPT: %s (model=%s, package=%s)\n' "$BOOT_RECEIPT" "$EXPECTED_MODEL" "$package"
  [ -n "$capacity_lines" ] || echo "WARNING: no capacity line captured; inspect docker logs $TARGET" >&2
  return 0
}

promote_restart_policy() {
  docker update --restart=unless-stopped "$TARGET" >/dev/null || {
    echo "error: could not promote $TARGET to restart=unless-stopped" >&2
    return 1
  }
  echo "PROMOTED: restart=unless-stopped"
}

restore_profiles() {
  local container failed=0
  for container in "$@"; do
    if ! docker start "$container" >/dev/null; then
      echo "error: rollback could not restart $container" >&2
      failed=1
    else
      echo "rollback restarted: $container"
    fi
  done
  return "$failed"
}

hyperflare_switch_main() {
  if ! [[ "$STARTUP_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: STARTUP_TIMEOUT_SECONDS must be a positive integer" >&2
    exit 2
  fi
  local active_output previous_output container
  local -a active previous stopped
  case "$MODE" in
    status)
      active_output="$(running_profiles)" || exit $?
      active=()
      [ -z "$active_output" ] || mapfile -t active <<<"$active_output"
      if [ "${#active[@]}" -eq 0 ]; then
        echo "No repository-owned inference profile is running."
      else
        printf 'running: %s\n' "${active[@]}"
      fi
      ;;
    stop)
      inference_stop_container_if_present "$TARGET"
      echo "Stopped $TARGET if it was present."
      ;;
    start)
      "$RUN" --preflight
      previous_output="$(running_profiles)" || exit $?
      previous=()
      [ -z "$previous_output" ] || mapfile -t previous <<<"$previous_output"
      for container in "${previous[@]}"; do
        if [ "$container" = "$TARGET" ]; then
          wait_for_target
          require_generation
          require_metrics_bridge
          report_boot_receipt
          promote_restart_policy
          exit 0
        fi
      done
      if [ "${#previous[@]}" -gt 0 ]; then
        inference_require_idle_endpoint
      fi
      stopped=()
      for container in "${previous[@]}"; do
        if ! inference_stop_container_if_present "$container"; then
          echo "error: profile quiesce failed; restoring already stopped profiles" >&2
          restore_profiles "${stopped[@]}" || true
          exit 1
        fi
        stopped+=("$container")
      done
      if ! "$RUN" --launch; then
        echo "error: Hyperflare $PROFILE_LABEL launch failed; restoring previous profile set" >&2
        restore_profiles "${previous[@]}" || true
        exit 1
      fi
      if ! wait_for_target || ! require_generation || ! require_metrics_bridge || ! report_boot_receipt \
         || ! promote_restart_policy; then
        docker logs --tail 200 "$TARGET" >&2 || true
        inference_quiesce_failed_container "$TARGET" || true
        echo "error: Hyperflare $PROFILE_LABEL acceptance failed; restoring previous profile set" >&2
        restore_profiles "${previous[@]}" || true
        exit 1
      fi
      ;;
    *) echo "usage: ${0##*/} {status|start|stop}" >&2; exit 2 ;;
  esac
}
