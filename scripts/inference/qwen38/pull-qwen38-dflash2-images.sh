#!/usr/bin/env bash
# Pull the DFlash 2 engine images built in GitHub Actions (published to GHCR by
# .github/workflows/build-dflash2-{sglang,vllm}-image.yml) onto the desktop,
# and re-tag them to the CANONICAL local names the launchers expect:
#
#   ghcr.io/<owner>/sglang:qwen38-dflash2-c14312a
#       -> peterstorm/sglang:qwen38-dflash2-c14312a
#   ghcr.io/<owner>/vllm:qwen38-dflash2-pr52816-19c9351
#       -> peterstorm/vllm:qwen38-dflash2-pr52816-19c9351
#
# Re-tagging means run-qwen38-27b-bf16-dflash2-sglang-native.sh (which defaults
# to the peterstorm/... tag) works with no override. Alternatively, skip the
# re-tag and point the launcher straight at GHCR:
#   DFLASH2_NATIVE_IMAGE=ghcr.io/<owner>/sglang:qwen38-dflash2-c14312a \
#     bash scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang-native.sh
#
# Auth: GHCR needs a login unless the package is public. Provide a PAT with
# read:packages via GHCR_TOKEN (and GHCR_USER, default = owner). If the package
# is public, an anonymous pull is attempted first and login is skipped.
#
# Usage:
#   bash pull-qwen38-dflash2-images.sh            # both images
#   bash pull-qwen38-dflash2-images.sh sglang     # SGLang only
#   bash pull-qwen38-dflash2-images.sh vllm       # vLLM only
#
# Overrides: GHCR_OWNER (default peterstorm), GHCR_USER, GHCR_TOKEN.
set -euo pipefail

GHCR_OWNER="${GHCR_OWNER:-peterstorm}"
GHCR_USER="${GHCR_USER:-$GHCR_OWNER}"
REGISTRY="ghcr.io"

declare -A SRC=(
  [sglang]="$REGISTRY/$GHCR_OWNER/sglang:qwen38-dflash2-c14312a"
  [vllm]="$REGISTRY/$GHCR_OWNER/vllm:qwen38-dflash2-pr52816-19c9351"
)
declare -A DST=(
  [sglang]="peterstorm/sglang:qwen38-dflash2-c14312a"
  [vllm]="peterstorm/vllm:qwen38-dflash2-pr52816-19c9351"
)

case "${1:-both}" in
  both) targets=(sglang vllm) ;;
  sglang) targets=(sglang) ;;
  vllm) targets=(vllm) ;;
  *) echo "usage: $0 {both|sglang|vllm}" >&2; exit 2 ;;
esac

command -v docker >/dev/null 2>&1 || { echo "error: docker is required" >&2; exit 1; }

logged_in=0
ghcr_login() {
  [ "$logged_in" -eq 1 ] && return 0
  if [ -n "${GHCR_TOKEN:-}" ]; then
    echo "Logging in to $REGISTRY as $GHCR_USER ..."
    printf '%s' "$GHCR_TOKEN" | docker login "$REGISTRY" -u "$GHCR_USER" --password-stdin
    logged_in=1
    return 0
  fi
  return 1
}

for key in "${targets[@]}"; do
  src="${SRC[$key]}"
  dst="${DST[$key]}"
  echo "== $key =="
  if ! docker pull "$src" 2>/dev/null; then
    # Anonymous pull failed (likely a private package): authenticate and retry.
    if ghcr_login; then
      docker pull "$src"
    else
      echo "error: could not pull $src and no GHCR_TOKEN was provided" >&2
      echo "  export GHCR_TOKEN=<PAT with read:packages> (and optionally GHCR_USER), then re-run" >&2
      echo "  or make the GHCR package public: https://github.com/users/$GHCR_OWNER/packages" >&2
      exit 1
    fi
  fi
  docker tag "$src" "$dst"
  echo "  $src"
  echo "  -> $dst"
  docker image inspect --format '  id: {{.Id}}' "$dst"
done

echo
echo "Done. The launchers now resolve their default image locally:"
echo "  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native   # SGLang, real DFlash 2, BF16 TP2"
echo "  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-vllm     # vLLM, DFlash 2 (PR #52816), BF16 TP2"
echo "Validate spec decode after boot:"
echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head -4"
