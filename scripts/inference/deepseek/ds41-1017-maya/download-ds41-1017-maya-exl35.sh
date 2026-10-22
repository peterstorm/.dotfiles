#!/usr/bin/env bash
# Download DeepSeek-V4.1-Flash-1017 as LibertAIDAI's EXL3 3.5 bpw for Project Maya.
#
# EXL3 3.5 bpw: perplexity over the unquantized model +0.8% (code) / +0.1%
# (prose) per the quant card. 257,641,444,616 bytes of weights (54 files)
# plus DeepSeek's two Engram tables from the base repo, 203,073,077,576 bytes:
# 460,714,522,192 bytes in all. Maya sizes it at ~280 GB of VRAM + RAM to
# hold everything, so on 2 x 96 GB + 96 GB almost nothing is read from the
# NVMe while answering (the UD-Q8_K_XL set needed ~305 GB and was SSD-bound).
#
# The file list, sizes and sha256s come from Maya's own manifest
# (tools/ds4/download-3.5bpw.json at Maya commit MAYA_COMMIT, vendored beside
# this script and checked against MANIFEST_SHA256), so the files land exactly
# where Maya's setup looks for them and its own verification accepts them:
#   $MODELS_DIR/DeepSeek-V4.1-Flash-1017-3.5bpw/
#
# Resumable and idempotent: curl -C - per file, a file whose size and sha256
# already verified is skipped. On success writes .download-complete into the
# model folder and a receipt under ~/.local/state/ds41-maya/.
#
# Usage: download-ds41-1017-maya-exl35.sh [--detach|--foreground|--status]
#   --detach (default): a transient system unit running as the invoking
#   user (sudo systemd-run): survives ssh and logout - the user has no linger
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/download-3.5bpw.json"
MANIFEST_SHA256="b30489b0462cab55b1b9a522b7b8d8134325db9d11b5f7caee07707fd84c8ace"
MAYA_COMMIT="b3fa99ec244e7885ec04ef456eac0d52474dba95"
FILE_COUNT=56
TOTAL_BYTES=460714522192
MODELS_DIR="${MODELS_DIR:-/models/ds41}"
DEST="$MODELS_DIR/DeepSeek-V4.1-Flash-1017-3.5bpw"
# The Engram tables live on their own 16K-record dataset (machines/desktop/
# disks.nix: models/ds41/engram), symlinked into DEST: the engine reads ~1 KB
# rows at random and the parent's 1M records turned each into a 1 MB read.
ENGRAM_DEST="$MODELS_DIR/engram"
STATE_DIR="$HOME/.local/state/ds41-maya"
RECEIPT="$STATE_DIR/exl35-download-receipt.txt"
UNIT="ds41-1017-maya-exl35-download"
JOBS="${JOBS:-3}"
MODE="${1:---detach}"

die() { echo "error: $*" >&2; exit 1; }

case "$MODE" in
  --status)
    systemctl status "$UNIT" --no-pager 2>/dev/null | head -5 || true
    du -sbL "$DEST" 2>/dev/null | awk -v t="$TOTAL_BYTES" '{printf "%.1f / %.1f GB on disk\n", $1/1e9, t/1e9}'
    if [ -f "$DEST/.download-complete" ]; then echo "complete: $(cat "$DEST/.download-complete")"; fi
    exit 0 ;;
  --detach)
    mkdir -p "$STATE_DIR"
    sudo systemctl reset-failed "$UNIT" 2>/dev/null || true
    sudo systemd-run --unit "$UNIT" --collect --uid "$(id -u)" --gid "$(id -g)" \
      -E HOME="$HOME" -E MODELS_DIR="$MODELS_DIR" -E JOBS="$JOBS" -E PATH="$PATH" \
      "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" --foreground
    echo "started $UNIT; follow: journalctl -fu $UNIT"
    exit 0 ;;
  --foreground) ;;
  *) die "unknown mode $MODE" ;;
esac

echo "$MANIFEST_SHA256  $MANIFEST" | sha256sum -c --quiet - || die "manifest does not match the pinned sha256"
mountpoint -q "$MODELS_DIR" || die "$MODELS_DIR is not mounted (rpool/models/ds41)"
mountpoint -q "$ENGRAM_DEST" || die "$ENGRAM_DEST is not mounted (rpool/models/ds41/engram)"

# One "dir repo revision name size sha256" line per file: the EXL3 repo's
# files into DEST, then the Engram tables from DeepSeek's base repo into
# ENGRAM_DEST. Parsed once.
mapfile -t FILES < <(jq -r --arg w "$DEST" --arg e "$ENGRAM_DEST" '
  ([$w, .], [$e, .engram]) as [$dir, $src] | $src.files | to_entries[]
  | [$dir, $src.repo, $src.revision, .key, .value[0], .value[1]] | map(tostring) | join(" ")' "$MANIFEST")
[ "${#FILES[@]}" -eq "$FILE_COUNT" ] || die "expected $FILE_COUNT files, manifest lists ${#FILES[@]}"
NEED="$(printf '%s\n' "${FILES[@]}" | awk '{s += $5} END {print s}')"
[ "$NEED" = "$TOTAL_BYTES" ] || die "manifest totals $NEED bytes, expected $TOTAL_BYTES"

mkdir -p "$DEST" "$STATE_DIR"
HAVE="$(du -sbL "$DEST" | cut -f1)"
FREE="$(df -B1 --output=avail "$MODELS_DIR" | tail -1)"
[ $((NEED - HAVE)) -lt "$FREE" ] || die "need $((NEED - HAVE)) more bytes, $FREE free"

# One file: resumed until it has its pinned size, then sha256-checked. A
# verified file is marked with <file>.ok so a re-run skips the re-hash.
fetch() {
  local dir=$1 repo=$2 rev=$3 name=$4 size=$5 sha=$6
  local out="$dir/$name"
  if [ -f "$out.ok" ] && [ "$(stat -c %s "$out")" = "$size" ]; then echo "ok (verified earlier) $name"; return 0; fi
  local attempt got
  for attempt in $(seq 1 50); do
    curl -sS -L --fail --retry 5 --retry-delay 10 --speed-limit 1048576 --speed-time 60 \
      -C - -o "$out" "https://huggingface.co/$repo/resolve/$rev/$name" && break
    got="$(stat -c %s "$out" 2>/dev/null || echo 0)"
    [ "$got" -ge "$size" ] && break
    echo "retry $attempt $name ($got / $size)"; sleep 15
  done
  [ "$(stat -c %s "$out")" = "$size" ] || { echo "size mismatch $name"; return 1; }
  echo "$sha  $out" | sha256sum -c --quiet - || { echo "sha256 mismatch $name"; return 1; }
  touch "$out.ok"; echo "ok $name"
}
export -f fetch

# The two 101.5 GB Engram tables go first so they never end up as the lone
# tail of the download.
printf '%s\n' "${FILES[@]}" | sort -k5,5nr | xargs -P "$JOBS" -L 1 bash -c 'fetch "$@"' _ \
  || die "one or more files failed; re-run to resume"

for f in "${FILES[@]}"; do
  read -r dir _ _ name _ _ <<<"$f"
  [ -f "$dir/$name.ok" ] || die "$name did not verify"
  # Maya looks for every file in DEST: the Engram tables are linked there.
  if [ "$dir" != "$DEST" ]; then ln -sfn "$dir/$name" "$DEST/$name"; fi
done
rm -f "$DEST"/*.ok "$ENGRAM_DEST"/*.ok
REPO="$(jq -r .repo "$MANIFEST")"; REV="$(jq -r .revision "$MANIFEST")"
echo "$REPO@$REV exl3-3.5 $NEED bytes, sha256-verified $(date -Is)" > "$DEST/.download-complete"
{
  echo "repo:      $REPO"
  echo "revision:  $REV"
  echo "engram:    $(jq -r '.engram | "\(.repo)@\(.revision)"' "$MANIFEST")"
  echo "quant:     EXL3 3.5 bpw ($NEED bytes, $FILE_COUNT files, every sha256 verified)"
  echo "manifest:  Maya $MAYA_COMMIT tools/ds4/download-3.5bpw.json sha256 $MANIFEST_SHA256"
  echo "dest:      $DEST"
  echo "finished:  $(date -Is)"
} > "$RECEIPT"
echo "done: $RECEIPT"
