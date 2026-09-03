#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/machines/desktop/comfyui.nix"
DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-fun-controlnet.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"
}

[ -x "$DOWNLOAD" ] || fail "downloader is missing or not executable"
bash -n "$DOWNLOAD"
nix-instantiate --parse "$MODULE" >/dev/null

contains "$MODULE" 'repo = "ComfyUI-H3-FunControl";'
contains "$MODULE" 'rev = "22a7ec38c4d16a76a8dea53b6e0faa0356f4f220";'
contains "$MODULE" 'hash = "sha256-UIKCkqMIbWeacsycqh1ZJ0R7szuioOwyigjOKMKamYs=";'
contains "$MODULE" 'ln -s ${h3FunControlNode} "$out/ComfyUI-H3-FunControl"'
contains "$MODULE" 'downloadMinimaxH3FunControlnet'
contains "$MODULE" 'assert tuple(rows.shape) == (8, 196)'

contains "$DOWNLOAD" 'MINIMAX_H3_ACCEPT_LICENSE'
contains "$DOWNLOAD" 'MINIMAX_H3_AUTHORIZED'
contains "$DOWNLOAD" 'REV="f4cac997f880e93cf6940af61ee8d58ef31ff7f3"'
contains "$DOWNLOAD" 'EXPECTED_SHA256="57fe1e64928a63a55e3cd4586b55cd5d0eb4980648b6f31e5d9dac16fe7f1c48"'
contains "$DOWNLOAD" 'EXPECTED_BYTES="4222169456"'
contains "$DOWNLOAD" 'controlnet/minimax_h3_fun_controlnet_union_pruned_bf16.safetensors'
contains "$DOWNLOAD" 'mv -f "$destination.new" "$destination"'
contains "$DOWNLOAD" 'rm -rf "$STAGING"'

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
echo called >>"$H3_FUN_CONTROL_EVENTS"
EOF
chmod +x "$sandbox/bin/hf"
: >"$sandbox/events"

status=0
H3_FUN_CONTROL_EVENTS="$sandbox/events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/models" bash "$DOWNLOAD" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing-license gate returned $status"
[ ! -s "$sandbox/events" ] || fail "downloader crossed the hf boundary before license acceptance"

status=0
H3_FUN_CONTROL_EVENTS="$sandbox/events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/models" MINIMAX_H3_ACCEPT_LICENSE=yes \
  bash "$DOWNLOAD" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing-authorization gate returned $status"
[ ! -s "$sandbox/events" ] || fail "downloader crossed the hf boundary before authorization"

printf 'PASS: MiniMax H3 Fun ControlNet is declarative, pinned, tested, and legally gated\n'
