#!/usr/bin/env bash
# Install the pinned MiniMax H3 Wushu Action V7 Ref2VA adapter for private,
# non-authoritative local qualification. The upstream repository declares its
# license only as "other" and provides no grant suitable for Production use.
set -euo pipefail

REPO="Jojocodex/wushu-action-v7-minimax-h3-fl2va-ref2va-lora"
REV="9abd1a8ae5edf0c8a1aea541bfd58b778273ca6a"
SOURCE="wushu_action_v7_ref2va_aitoolkit_NO-ADALN_pruned-int8convrot_2000step.safetensors"
EXPECTED_SHA256="f070becda73c65a19a8204384db51bb8204d2303055852172c25aa699589326e"
EXPECTED_BYTES="310167928"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
DESTINATION="$MODELS_ROOT/loras/$SOURCE"
STAGING="$MODELS_ROOT/.staging-minimax-h3-wushu-v7-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-wushu-v7-research-only-complete"
LOCK="$MODELS_ROOT/.minimax-h3-wushu-v7-download.lock"
MODEL_CARD="https://huggingface.co/$REPO/tree/$REV"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != yes ] || [ "${MINIMAX_H3_AUTHORIZED:-}" != yes ]; then
  cat >&2 <<'EOF'
error: H3 adapter use remains subject to the MiniMax H3 base-model terms and
separate territorial authorization. Set both MINIMAX_H3_ACCEPT_LICENSE=yes and
MINIMAX_H3_AUTHORIZED=yes only while those conditions remain satisfied.
EOF
  exit 2
fi
if [ "${MINIMAX_H3_WUSHU_V7_RESEARCH_ONLY:-}" != yes ]; then
  cat >&2 <<EOF
error: Wushu Action V7 declares its license only as "other" and supplies no
Production or commercial-use grant. Review $MODEL_CARD and set
MINIMAX_H3_WUSHU_V7_RESEARCH_ONLY=yes only for private local Development
qualification. This acknowledgment does not create rights or authorize release.
EOF
  exit 2
fi
for command in flock hf sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

verify_file() {
  local file=$1 actual_bytes actual_sha256
  [ -f "$file" ] || return 1
  actual_bytes=$(stat -c %s "$file")
  [ "$actual_bytes" = "$EXPECTED_BYTES" ] || return 1
  actual_sha256=$(sha256sum "$file" | cut -d' ' -f1)
  [ "$actual_sha256" = "$EXPECTED_SHA256" ]
}

write_marker() {
  {
    printf '%s\n' "$REPO@$REV"
    printf 'status=private-local-development-qualification-only\n'
    printf 'license=upstream-other-no-production-grant-established\n'
    printf '%s %s loras/%s\n' "$EXPECTED_SHA256" "$EXPECTED_BYTES" "$SOURCE"
  } >"$MARKER.new"
  chmod 0640 "$MARKER.new"
  mv -f "$MARKER.new" "$MARKER"
}

mkdir -p "$MODELS_ROOT/loras"
exec 9>"$LOCK"
flock 9

if verify_file "$DESTINATION"; then
  write_marker
  echo "MINIMAX_H3_WUSHU_V7_RESEARCH_READY: $REPO@$REV"
  exit 0
fi

mkdir -p "$STAGING"
hf download "$REPO" "$SOURCE" --revision "$REV" --local-dir "$STAGING"
verify_file "$STAGING/$SOURCE" || {
  echo "error: downloaded Wushu V7 adapter failed exact size or SHA-256 verification" >&2
  exit 1
}

install -m 0640 "$STAGING/$SOURCE" "$DESTINATION.new"
mv -f "$DESTINATION.new" "$DESTINATION"
write_marker
rm -rf "$STAGING"

echo "MINIMAX_H3_WUSHU_V7_RESEARCH_READY: $REPO@$REV"
echo "adapter: $DESTINATION"
echo "status: private local Development qualification only; authority none"
