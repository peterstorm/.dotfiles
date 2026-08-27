#!/usr/bin/env bash
# Download and verify brandonmusic/GLM-5.3-Flash-EXL3-4bpw (~163.7 GiB).
# Idempotent and resumable; completion is marked only after all 135 serving artifacts hash.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="brandonmusic/GLM-5.3-Flash-EXL3-4bpw"
REV="4739eb1bcfd478e8a32da6358908567bc3a9ac51"
DEST="${DEST:-/models/GLM-5.3-Flash-EXL3-K4-v1}"
MANIFEST_FILE="$SCRIPT_DIR/glm53-flash-exl3-k4-v1.manifest"
MANIFEST_SHA256="96bb2e8ebdc287233c142f05465ac180c34c25e47a3b8ef338882faced3f52b7"
PYTHON_IMAGE="python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
NAME="glm53-exl3-k4-v1-model-dl"

if [ "$(sha256sum "$MANIFEST_FILE" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  echo "error: checked-in EXL3 checkpoint manifest identity does not match" >&2
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

cat > /tmp/glm53-exl3-k4-v1-download.py <<'PY'
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
quant = json.loads((root / "quantization_config.json").read_text())
receipt = json.loads((root / "materialization-receipt.json").read_text())
index = json.loads((root / "model.safetensors.index.json").read_text())
if config.get("architectures") != ["Glm5NextForConditionalGeneration"]:
    raise SystemExit("unexpected model architecture")
if config.get("model_type") != "glm5_next":
    raise SystemExit("unexpected model_type")
if config["text_config"].get("max_position_embeddings") != 1_048_576:
    raise SystemExit("unexpected native context length")
expected_quant = {
    "bits": 4,
    "codebook": "mcg",
    "non_routed_dtype_policy": "official_source_native",
    "quant_method": "exl3",
    "scope": "glm53_routed_experts_only",
    "version": "0.0.43",
}
if any(quant.get(key) != value for key, value in expected_quant.items()):
    raise SystemExit("unexpected EXL3 K4 quantization contract")
if quant.get("serving_reader_qualified") is not False:
    raise SystemExit("unexpected upstream serving-reader qualification state")
if receipt.get("schema") != "quant-pipeline.glm53-k4-materialization-receipt.v1":
    raise SystemExit("unexpected materialization receipt schema")
if receipt.get("complete") is not True or receipt.get("main_and_mtp_complete") is not True:
    raise SystemExit("incomplete EXL3 materialization receipt")
if receipt.get("output_logical_bytes") != 175_622_979_576:
    raise SystemExit("unexpected materialized tensor bytes")
if receipt.get("output_tensor_count") != 150_226 or receipt.get("packed_tensor_count") != 148_608:
    raise SystemExit("unexpected materialized tensor census")
if receipt.get("source_model_revision") != "a6c167b62691b2bac901344b65cb651a70f53e43":
    raise SystemExit("unexpected BF16 source revision")
if index.get("metadata", {}).get("total_size") != 175_622_979_576:
    raise SystemExit("unexpected indexed tensor byte count")
if len(index.get("weight_map", {})) != 150_226:
    raise SystemExit("unexpected indexed tensor count")

marker = root / ".download-complete"
temporary = root / ".download-complete.tmp"
temporary.write_text(f"{repo}@{revision}\n")
os.replace(temporary, marker)
print(f"verified {len(records)} records; DOWNLOAD_COMPLETE")
PY
chmod 600 /tmp/glm53-exl3-k4-v1-download.py

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$DEST:$DEST" \
  -v "$MANIFEST_FILE:/checkpoint.manifest:ro" \
  -v /tmp/glm53-exl3-k4-v1-download.py:/download.py:ro \
  "${TOKEN_MOUNT[@]}" \
  "$PYTHON_IMAGE" \
  bash -ceu "pip install --no-cache-dir 'huggingface_hub[hf_xet]==0.34.4'; export HF_XET_HIGH_PERFORMANCE=1; python /download.py '$REPO' '$REV' '$DEST' /checkpoint.manifest"

printf "Downloading in container '%s'. Follow with: docker logs -f %s\n" "$NAME" "$NAME"
printf "Completion marker: %s/.download-complete\n" "$DEST"
