#!/usr/bin/env bash
# Reject a Flash-Next deployment whose greedy prefill top-20 vector changes across identical requests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"

URL="${URL:-http://127.0.0.1:8000}"
MODEL="${MODEL:-qwen3.8-flash-next-fp8}"
ITERATIONS="${ITERATIONS:-10}"
FIXTURE="$ROOT/tests/fixtures/qwen38-flash-next/D2.md"
EXPECTED_FIXTURE_SHA256="8449957bd502008cfc42ed500c490a5d2777267e50c58416859a6c717e579a92"

if ! [[ "$ITERATIONS" =~ ^[0-9]+$ ]] || (( ITERATIONS < 2 || ITERATIONS > 20 )); then
  echo "error: ITERATIONS must be an integer in [2, 20]" >&2
  exit 2
fi
[ "$(sha256sum "$FIXTURE" | cut -d" " -f1)" = "$EXPECTED_FIXTURE_SHA256" ] || {
  echo "error: determinism fixture identity differs" >&2
  exit 1
}
inference_resolve_client_keyfile || {
  echo "error: no synchronized inference API key is available" >&2
  exit 1
}
key="$(<"$INFERENCE_CLIENT_KEYFILE")"

system_prompt='Magyar dokumentumfeldolgozó asszisztens vagy. Kizárólag a megadott dokumentum alapján válaszolj. A választ pontosan a kért JSON-sémában add vissza, minden más szöveg nélkül. Ha egy kért adat nem szerepel a dokumentumban, az értéke legyen: "nincs az iratban".'
user_prompt="$(jq -nr --rawfile document "$FIXTURE" '
  "===== D2.md =====\n\n" + $document +
  "\n\n===== FELADAT =====\n\n" +
  "A vállalkozó számláját 2026. október 19-én, hétfőn vettük kézhez. A szerződés 3.4. pontja szerinti fizetési határidő mely napon jár le?" +
  "\n\n===== A VÁLASZ JSON-SÉMÁJA =====\n\n" +
  "{\n  \"hatarido\": \"YYYY-MM-DD\",\n  \"szamitas_alapja\": \"munkanap | naptári nap\"\n}" +
  "\n\nKizárólag a fenti séma szerinti JSON-t add vissza."
')"
payload="$(jq -cn --arg model "$MODEL" --arg system "$system_prompt" --arg user "$user_prompt" '{
  model: $model,
  temperature: 0.0,
  top_p: 1,
  max_tokens: 1,
  logprobs: true,
  top_logprobs: 20,
  messages: [{role: "system", content: $system}, {role: "user", content: $user}]
}')"

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
for run in $(seq 1 "$ITERATIONS"); do
  running="$(curl -fsS --connect-timeout 2 --max-time 5 "$URL/metrics" | awk '/^vllm:num_requests_running[{]/{print $2; exit}')"
  [ "$running" = "0.0" ] || {
    echo "error: determinism probe requires an idle engine; found $running running requests before run $run" >&2
    exit 1
  }
  http_status="$(curl --silent --show-error --output "$temporary/response-$run.json" --write-out '%{http_code}' \
    --connect-timeout 5 --max-time 300 --header "Content-Type: application/json" \
    --header "Connection: close" --config - --data-binary "$payload" <<EOF_CURL
url = "$URL/v1/chat/completions"
header = "Authorization: Bearer $key"
EOF_CURL
)"
  [ "$http_status" = 200 ] || {
    echo "error: determinism probe run $run returned HTTP $http_status" >&2
    jq -c '{error}' "$temporary/response-$run.json" >&2 || true
    exit 1
  }
  jq -ce '.choices[0].logprobs.content[0] as $first |
    {token: $first.token, logprob: $first.logprob,
     vector: ($first.top_logprobs | map([.token, .logprob]))}' \
    "$temporary/response-$run.json" >"$temporary/extracted-$run.json"
  jq -c '.vector' "$temporary/extracted-$run.json" | sha256sum | cut -d" " -f1 >>"$temporary/vector-hashes"
  printf "run=%d token=%s logprob=%s top20_sha256=%s\n" \
    "$run" \
    "$(jq -r '.token' "$temporary/extracted-$run.json")" \
    "$(jq -r '.logprob' "$temporary/extracted-$run.json")" \
    "$(tail -1 "$temporary/vector-hashes")"
done

distinct="$(sort -u "$temporary/vector-hashes" | wc -l)"
[ "$distinct" -eq 1 ] || {
  echo "FAIL: greedy prefill is non-deterministic ($distinct top-20 vectors across $ITERATIONS runs)" >&2
  exit 1
}
echo "PASS: greedy prefill is byte-identical across $ITERATIONS runs"
