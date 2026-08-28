#!/usr/bin/env bash
# Download and verify the 2.18 GiB GLM-5.3 DFlash2 draft checkpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="incoai/GLM-5.3-Flash-DFlash2"
REV="7d74cdd881ed7e32c31175984a67823127b66cfe"
DEST="${DEST:-/models/GLM-5.3-Flash-DFlash2-v1}"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-dflash2-v1.manifest"
MANIFEST_SHA256="9979f7d652cd5c971d1db6a5b6093bdd271e711855fcbf22371ecc767d332c9d"
PYTHON_IMAGE="python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
NAME="glm53-flash-dflash2-v1-model-dl"

if [ "$(sha256sum "$MANIFEST_FILE" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  echo "error: checked-in DFlash2 manifest identity does not match" >&2
  exit 1
fi
if [ -L "$DEST" ]; then
  echo "error: checkpoint destination must not be a symbolic link: $DEST" >&2
  exit 1
fi
if ! mkdir -p "$DEST" 2>/dev/null || [ ! -w "$DEST" ]; then
  sudo mkdir -p "$DEST"
  sudo chown "$(id -u):$(id -g)" "$DEST"
fi

TOKEN_FILE="${HF_TOKEN_FILE:-$HOME/.config/hf/token}"
TOKEN_MOUNT=()
if [ -f "$TOKEN_FILE" ]; then
  TOKEN_MOUNT=(-v "$TOKEN_FILE:/root/.cache/huggingface/token:ro")
else
  echo "note: no HF token at $TOKEN_FILE; downloading this public checkpoint anonymously" >&2
fi

cat >/tmp/glm53-flash-dflash2-v1-download.py <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time

from huggingface_hub import snapshot_download

repo, revision, destination, manifest_path = sys.argv[1:]
root = pathlib.Path(destination)
records = []
for line in pathlib.Path(manifest_path).read_text().splitlines():
    fields = line.split("\t")
    if len(fields) != 3 or len(fields[0]) != 64 or not fields[1].isdigit():
        raise SystemExit(f"invalid manifest record: {line!r}")
    digest, size, relative = fields
    path = pathlib.PurePosixPath(relative)
    if path.is_absolute() or ".." in path.parts:
        raise SystemExit(f"unsafe manifest path: {relative!r}")
    records.append((digest, int(size), relative))

for attempt in range(1, 9):
    try:
        snapshot_download(
            repo_id=repo,
            revision=revision,
            local_dir=root,
            allow_patterns=[relative for _, _, relative in records],
            max_workers=2,
        )
        break
    except (OSError, RuntimeError) as error:
        if attempt == 8:
            raise
        delay = min(30 * attempt, 180)
        print(f"transient download failure ({error}); retry {attempt}/8 in {delay}s", flush=True)
        time.sleep(delay)

for expected_digest, expected_size, relative in records:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"missing or symbolic draft artifact: {path}")
    if path.stat().st_size != expected_size:
        raise SystemExit(f"size mismatch for {path}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest:
        raise SystemExit(f"SHA-256 mismatch for {path}")

config = json.loads((root / "config.json").read_text())
expected_dflash = {
    "block_size": 8,
    "conv_group_size": 16,
    "conv_kernel_size": 2,
    "mask_token_id": 154856,
    "selector_rank": 256,
    "selector_top_k": 16,
    "target_layer_ids": [5, 14, 24, 33, 42],
}
if config.get("architectures") != ["DFlash2DraftModel"]:
    raise SystemExit("unexpected DFlash2 architecture")
if config.get("dflash_config") != expected_dflash:
    raise SystemExit("unexpected DFlash2 block/selector contract")
if config.get("num_hidden_layers") != 5 or config.get("sliding_window") != 2048:
    raise SystemExit("unexpected DFlash2 depth or window")
if config.get("dtype") != "bfloat16" or config.get("vocab_size") != 154880:
    raise SystemExit("unexpected DFlash2 dtype or vocabulary")
readme = (root / "README.md").read_text()
if "license: cc-by-nc-nd-4.0" not in readme or "zai-org/GLM-5.3-Flash" not in readme:
    raise SystemExit("unexpected DFlash2 license or target declaration")

marker = root / ".download-complete"
temporary = root / ".download-complete.tmp"
temporary.write_text(f"{repo}@{revision}\n")
os.replace(temporary, marker)
print(f"verified {len(records)} records; DOWNLOAD_COMPLETE")
PY
chmod 600 /tmp/glm53-flash-dflash2-v1-download.py

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$DEST:$DEST" \
  -v "$MANIFEST_FILE:/checkpoint.manifest:ro" \
  -v /tmp/glm53-flash-dflash2-v1-download.py:/download.py:ro \
  "${TOKEN_MOUNT[@]}" \
  "$PYTHON_IMAGE" \
  bash -ceu "pip install --no-cache-dir 'huggingface_hub[hf_xet]==0.34.4'; export HF_XET_HIGH_PERFORMANCE=1; python /download.py '$REPO' '$REV' '$DEST' /checkpoint.manifest"

printf "Downloading in container '%s'. Follow with: docker logs -f %s\n" "$NAME" "$NAME"
printf "Completion marker: %s/.download-complete\n" "$DEST"
