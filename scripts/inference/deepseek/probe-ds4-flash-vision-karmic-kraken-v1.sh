#!/usr/bin/env bash
# Authenticated text + synthetic-red-image acceptance probe for the DeepSeek
# V4 Flash Vision Karmic Kraken v1 profile (ds4-vision, DSpark K3).
set -euo pipefail

MODEL="${MODEL:-deepseek-v4-flash-vision}"
KEYFILE="${KEYFILE:-$HOME/.config/ds4-flash/api-key}"
IMAGE="sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee"
[[ -r "$KEYFILE" ]] || { echo "error: API key is unavailable: $KEYFILE" >&2; exit 1; }
key="$(<"$KEYFILE")"
escaped_key="${key//\\/\\\\}"
escaped_key="${escaped_key//\"/\\\"}"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

request() {
  local payload="$1"
  curl --fail --silent --show-error --config - \
    --header 'Content-Type: application/json' --data-binary "$payload" <<EOF
url = "http://127.0.0.1:8000/v1/chat/completions"
header = "Authorization: Bearer $escaped_key"
max-time = 900
EOF
}

text_payload="$(jq -cn --arg model "$MODEL" '{
  model:$model,
  temperature:0,
  max_tokens:256,
  reasoning_effort:"low",
  messages:[{role:"user",content:"What is the capital of France? Answer in one sentence."}]
}')"
text_response="$(request "$text_payload")"
text_output="$(jq -r '[.choices[0].message.reasoning_content // "", .choices[0].message.reasoning // "", .choices[0].message.content // ""] | join("\n")' <<<"$text_response")"
grep -Eqi 'Paris' <<<"$text_output" || {
  echo "error: text probe did not identify Paris" >&2
  jq -c . <<<"$text_response" >&2
  exit 1
}

docker run --rm -i --runtime runc --network none \
  -v "$tmpdir:/out" --entrypoint /opt/venv/bin/python "$IMAGE" - <<'PY'
from PIL import Image
Image.new("RGB", (96, 96), (255, 0, 0)).save("/out/ds4-vision-red.png")
PY
image_b64="$(base64 -w0 "$tmpdir/ds4-vision-red.png")"
vision_payload="$(jq -cn --arg model "$MODEL" --arg image "data:image/png;base64,$image_b64" '{
  model:$model,
  temperature:0,
  max_tokens:512,
  reasoning_effort:"low",
  messages:[{role:"user",content:[
    {type:"image_url",image_url:{url:$image}},
    {type:"text",text:"What is the single dominant color in this image?"}
  ]}]
}')"
vision_response="$(request "$vision_payload")"
vision_output="$(jq -r '[.choices[0].message.reasoning_content // "", .choices[0].message.reasoning // "", .choices[0].message.content // ""] | join("\n")' <<<"$vision_response")"
grep -Eqi 'red' <<<"$vision_output" || {
  echo "error: vision probe did not identify red" >&2
  jq -c . <<<"$vision_response" >&2
  exit 1
}

printf 'PASS: DS4 Vision (Karmic Kraken v1) answered text and synthetic-red-image probes\n'
