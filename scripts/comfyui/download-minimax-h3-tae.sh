#!/usr/bin/env bash
# Download the H3 sampling preview VAE for the Model Preview Override nodes:
# Kijai's MiniMax-H3-TAE export, installed under models/vae_approx so the
# preview override tiny_vae box finds taeh3.safetensors. Tiny cosmetic preview
# only - the workflow runs fine without it.
set -euo pipefail

REPO="Kijai/MiniMax-H3-TAE"
REV="a213ac8bf2f148b4f32372279a7f207846978900"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-minimax-h3-tae-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-tae-complete"
LOCK="$MODELS_ROOT/.minimax-h3-tae-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
The MiniMax-H3-TAE export is a derivative of MiniMax H3, whose original model
is governed by the MiniMax-H3 Community License; do not infer Apache-2.0 from
a repackaged repository card. Set MINIMAX_H3_ACCEPT_LICENSE=yes only after
reviewing:
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE
EOF
  exit 2
fi
if [ "${MINIMAX_H3_AUTHORIZED:-}" != "yes" ]; then
  echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
  exit 2
fi
if ! command -v hf >/dev/null 2>&1; then
  echo "error: the Hugging Face 'hf' CLI is required" >&2
  exit 1
fi
for command in flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

# sha256, exact bytes, destination relative to ComfyUI's model root
read -r -d '' MANIFEST <<'EOF' || true
f0f60fa072089997f817402098c2fd90777cb2660dd79cf5df42fc1e3e08e527 9791388 vae_approx/taeh3.safetensors
EOF

verify_manifest() {
  local root="$1" expected_sha expected_size relative file actual_size actual_sha
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    if [ ! -f "$file" ]; then
      echo "missing: $relative" >&2
      return 1
    fi
    actual_size="$(stat -c %s "$file")"
    if [ "$actual_size" != "$expected_size" ]; then
      echo "size mismatch: $relative (expected $expected_size, got $actual_size)" >&2
      return 1
    fi
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "checksum mismatch: $relative" >&2
      return 1
    fi
    printf 'verified: %s (%s bytes)\n' "$relative" "$actual_size"
  done <<<"$MANIFEST"
  return 0
}

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "another minimax-h3-tae download is already running" >&2
  exit 1
fi

if verify_manifest "$MODELS_ROOT"; then
  printf 'MiniMax H3 TAE already installed and verified at %s\n' "$MODELS_ROOT"
  exit 0
fi

rm -rf "$STAGING"
mkdir -p "$STAGING/vae_approx" "$MODELS_ROOT/vae_approx"

printf 'downloading MiniMax-H3-TAE at revision %s\n' "$REV"
hf download "$REPO" \
  --revision "$REV" \
  --local-dir "$STAGING" \
  vae_approx/taeh3.safetensors

if ! verify_manifest "$STAGING"; then
  echo "downloaded staging tree failed checksum verification; nothing installed" >&2
  rm -rf "$STAGING"
  exit 1
fi

install -m 0444 "$STAGING/vae_approx/taeh3.safetensors" \
  "$MODELS_ROOT/vae_approx/taeh3.safetensors.tmp"
mv "$MODELS_ROOT/vae_approx/taeh3.safetensors.tmp" \
  "$MODELS_ROOT/vae_approx/taeh3.safetensors"
rm -rf "$STAGING"

if ! verify_manifest "$MODELS_ROOT"; then
  echo "post-install verification failed" >&2
  exit 1
fi
date >"$MARKER"
printf 'MiniMax H3 TAE installed at %s/vae_approx/taeh3.safetensors\n' "$MODELS_ROOT"
