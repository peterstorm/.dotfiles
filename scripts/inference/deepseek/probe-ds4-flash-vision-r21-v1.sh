#!/usr/bin/env bash
# Authenticated text + synthetic-red-image acceptance probe for DS4 Vision.
set -euo pipefail

MODEL="${MODEL:-deepseek-v4-flash-vision}"
KEYFILE="${KEYFILE:-$HOME/.config/ds4-flash/api-key}"
IMAGE="sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183"
[[ -r "$KEYFILE" ]] || { echo "error: API key is unavailable: $KEYFILE" >&2; exit 1; }
key="$(<"$KEYFILE")"

request() {
  local payload="$1"
  curl --fail --silent --show-error --config - \
    --header 'Content-Type: application/json' --data-binary "$payload" <<EOF
url = "http://127.0.0.1:8000/v1/chat/completions"
header = "Authorization: Bearer $key"
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

docker run --rm -i -v /tmp:/out --entrypoint python3 "$IMAGE" - <<'PY'
from PIL import Image
Image.new("RGB", (96, 96), (255, 0, 0)).save("/out/ds4-vision-red.png")
PY
image_b64="$(base64 -w0 /tmp/ds4-vision-red.png)"
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

printf 'PASS: DS4 Vision answered text and synthetic-red-image probes\n'
