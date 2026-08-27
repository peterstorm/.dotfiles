#!/usr/bin/env bash
# Download and verify local-inference-lab/GLM-5.3-Flash-NVFP4 (~184.5 GiB).
# Idempotent and resumable; completion is marked only after all 53 artifacts hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="local-inference-lab/GLM-5.3-Flash-NVFP4"
REV="520de24eabf507659eaef7c70f14fd584527facc"
DEST="${DEST:-/models/GLM-5.3-Flash-NVFP4-v1}"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-nvfp4-v1.manifest"
MANIFEST_SHA256="98ce8b429c9e8959aa3eccd0a79dc52a6e7901ea0fae1451323d887a1590e9ca"
PYTHON_IMAGE="python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
NAME="glm53-nvfp4-v1-model-dl"

if [ "$(sha256sum "$MANIFEST_FILE" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  echo "error: checked-in checkpoint manifest identity does not match" >&2
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

cat > /tmp/glm53-nvfp4-v1-download.py <<'PY'
import hashlib
import json
import os
import pathlib
import sys

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

snapshot_download(
    repo_id=repo,
    revision=revision,
    local_dir=root,
    allow_patterns=[relative for _, _, relative in records],
)

for expected_digest, expected_size, relative in records:
    path = root / relative
    if path.is_symlink() or not path.is_file():
        raise SystemExit(f"missing or symbolic checkpoint artifact: {path}")
    actual_size = path.stat().st_size
    if actual_size != expected_size:
        raise SystemExit(f"size mismatch for {path}: expected {expected_size}, got {actual_size}")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(16 * 1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected_digest:
        raise SystemExit(f"SHA-256 mismatch for {path}")

config = json.loads((root / "config.json").read_text())
quant = json.loads((root / "hf_quant_config.json").read_text())
index = json.loads((root / "model.safetensors.index.json").read_text())
if config.get("architectures") != ["Glm5NextForConditionalGeneration"]:
    raise SystemExit("unexpected model architecture")
if config.get("model_type") != "glm5_next":
    raise SystemExit("unexpected model_type")
if config["text_config"].get("max_position_embeddings") != 1_048_576:
    raise SystemExit("unexpected native context length")
if quant.get("quant_method") != "modelopt" or quant.get("quant_algo") != "MIXED_PRECISION":
    raise SystemExit("unexpected ModelOpt quantization contract")
algorithms = {entry["quant_algo"] for entry in quant["quantized_layers"].values()}
if algorithms != {"NVFP4", "MXFP8"}:
    raise SystemExit(f"unexpected mixed-precision algorithms: {algorithms}")
if index["metadata"].get("total_size") != 198_042_331_512:
    raise SystemExit("unexpected indexed tensor byte count")

marker = root / ".download-complete"
temporary = root / ".download-complete.tmp"
temporary.write_text(f"{repo}@{revision}\n")
os.replace(temporary, marker)
print(f"verified {len(records)} records; DOWNLOAD_COMPLETE")
PY
chmod 600 /tmp/glm53-nvfp4-v1-download.py

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$DEST:$DEST" \
  -v "$MANIFEST_FILE:/checkpoint.manifest:ro" \
  -v /tmp/glm53-nvfp4-v1-download.py:/download.py:ro \
  "${TOKEN_MOUNT[@]}" \
  "$PYTHON_IMAGE" \
  bash -ceu "pip install --no-cache-dir 'huggingface_hub[hf_xet]==0.34.4'; export HF_XET_HIGH_PERFORMANCE=1; python /download.py '$REPO' '$REV' '$DEST' /checkpoint.manifest"

printf "Downloading in container '%s'. Follow with: docker logs -f %s\n" "$NAME" "$NAME"
printf "After DOWNLOAD_COMPLETE, re-check at any time with: %s/verify-glm53-flash-nvfp4-v1.sh\n" "$SCRIPT_DIR"
