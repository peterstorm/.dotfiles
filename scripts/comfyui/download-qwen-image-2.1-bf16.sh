#!/usr/bin/env bash
# Immutable BF16-only Qwen Image 2.1 ComfyUI closure. Research license:
# https://huggingface.co/Qwen/Qwen-Image-2.1/blob/main/LICENSE
set -euo pipefail

repo=Comfy-Org/Qwen-Image-2.1
revision=5dc5850eb514a3685f6a03a2641728a8f7549c69
root=${COMFYUI_MODELS_ROOT:-/models/comfyui}
manifest=${QWEN_IMAGE_21_MANIFEST:-$(dirname "$0")/qwen-image-2.1-bf16.manifest}
marker="$root/.qwen-image-2.1-bf16-$revision.complete"
staging="$root/.staging-qwen-image-2.1-bf16-$revision"

[[ -f "$manifest" ]] || { echo "missing pinned manifest: $manifest" >&2; exit 1; }
for command in hf flock sha256sum stat; do
  command -v "$command" >/dev/null || { echo "missing command: $command" >&2; exit 1; }
done

verify() {
  local base=$1 hash=$2 size=$3 name=$4 actual
  [[ -f "$base/$name" && ! -L "$base/$name" ]] || return 1
  [[ $(stat -c %s "$base/$name") == "$size" ]] || return 1
  actual=$(sha256sum "$base/$name")
  [[ ${actual%% *} == "$hash" ]]
}

verify_all() {
  local base=$1 hash size name
  while read -r hash size name; do
    [[ -n "$hash" && ${hash:0:1} != '#' ]] || continue
    verify "$base" "$hash" "$size" "$name" || return 1
  done <"$manifest"
}

if [[ ${1:-} == --verify-only ]]; then
  [[ $# == 1 && -f "$marker" ]] && grep -Fxq "$repo@$revision" "$marker" \
    && verify_all "$root" || { echo 'Qwen 2.1 BF16 closure is not ready' >&2; exit 1; }
  echo "QWEN_IMAGE_21_BF16_READY: $repo@$revision"
  exit 0
fi
[[ $# == 0 ]] || { echo 'usage: download-qwen-image-2.1-bf16 [--verify-only]' >&2; exit 64; }
mkdir -p "$root"
exec 9>"$root/.qwen-image-2.1-bf16.lock"
flock 9
if [[ -f "$marker" ]] && grep -Fxq "$repo@$revision" "$marker" && verify_all "$root"; then
  echo "QWEN_IMAGE_21_BF16_READY: $repo@$revision"
  exit 0
fi

mkdir -p "$staging"
while read -r hash size name; do
  [[ -n "$hash" && ${hash:0:1} != '#' ]] || continue
  if ! verify "$root" "$hash" "$size" "$name" && ! verify "$staging" "$hash" "$size" "$name"; then
    hf download "$repo" "$name" --revision "$revision" --local-dir "$staging"
  fi
  if ! verify "$root" "$hash" "$size" "$name"; then
    verify "$staging" "$hash" "$size" "$name" || {
      echo "checksum/size mismatch: $name" >&2
      exit 1
    }
  fi
done <"$manifest"

while read -r hash size name; do
  [[ -n "$hash" && ${hash:0:1} != '#' ]] || continue
  if ! verify "$root" "$hash" "$size" "$name"; then
    mkdir -p "$root/$(dirname "$name")"
    mv -f "$staging/$name" "$root/$name.new"
    chmod 0640 "$root/$name.new"
    mv -f "$root/$name.new" "$root/$name"
  fi
done <"$manifest"
verify_all "$root" || { echo 'installed closure failed verification' >&2; exit 1; }
{
  printf '%s@%s\n' "$repo" "$revision"
  grep -v '^#' "$manifest"
  printf 'license=Qwen Research License; non-commercial research/evaluation only\n'
} >"$marker.new"
chmod 0640 "$marker.new"
mv -f "$marker.new" "$marker"
rm -rf "$staging"
echo "QWEN_IMAGE_21_BF16_READY: $repo@$revision"
