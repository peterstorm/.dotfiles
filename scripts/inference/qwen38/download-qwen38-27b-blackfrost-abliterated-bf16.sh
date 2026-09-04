#!/usr/bin/env bash
# Download and verify Blackfrost's abliterated Qwen3.8-27B BF16 master (51.77 GiB).
#
# This is a weight-level derivative of Qwen/Qwen3.8-27B with a reduced refusal
# surface, not the upstream safety-stock checkpoint. It is architecturally
# identical to /models/Qwen3.8-27B — same Qwen3_5ForConditionalGeneration
# architecture, same qwen3_5_text 262144-token contract, same 64 layers — so it
# serves through the existing TP1 vLLM profile shape rather than a new one.
#
# Every artifact is pinned by size and SHA-256 in the checked-in manifest, and
# the manifest itself is pinned by its own digest, so a tampered manifest fails
# before any network access.
#
# Xet is disabled deliberately. hf-xet 1.6.0 stalls on this workstation exactly as
# it does for Muse: the shard .incomplete files sit at zero bytes indefinitely with
# no transfer. Standard Hub HTTPS is slower but resumable and observable. See the
# same note in scripts/inference/muse/download-muse-glimmer-30b.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16"
REV="9d85770e5eb602322b4bceef55beda357e0bd0ca"
DEST="${DEST:-/models/Qwen3.8-27B-Blackfrost-Abliterated-BF16}"
MANIFEST_FILE="$SCRIPT_DIR/qwen38-27b-blackfrost-abliterated-bf16-v1.manifest"
MANIFEST_SHA256="5fb7e9d4daf9c9be6616a5026b704c34de31cb046a2ea6f72bf65c8007899a6c"
PYTHON_IMAGE="python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
NAME="qwen38-27b-blackfrost-abliterated-bf16-model-dl"

if [ "$(sha256sum "$MANIFEST_FILE" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  echo "error: checked-in Blackfrost Qwen manifest identity does not match" >&2
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

cat > /tmp/qwen38-27b-blackfrost-abliterated-bf16-download.py <<'PY'
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
            max_workers=4,
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
index = json.loads((root / "model.safetensors.index.json").read_text())
text = config.get("text_config", {})

# The abliteration is a weight-level edit only. Any structural divergence from
# the upstream 27B contract means this is not the checkpoint the vLLM profile
# was qualified against, so refuse it rather than serve a surprise.
if config.get("architectures") != ["Qwen3_5ForConditionalGeneration"]:
    raise SystemExit("unexpected Blackfrost Qwen architecture")
if config.get("model_type") != "qwen3_5" or text.get("model_type") != "qwen3_5_text":
    raise SystemExit("unexpected Blackfrost Qwen model type")
if text.get("max_position_embeddings") != 262_144:
    raise SystemExit("unexpected native context contract")
if text.get("num_hidden_layers") != 64:
    raise SystemExit("unexpected layer count")
if config.get("quantization_config") is not None:
    raise SystemExit("BF16 master must not carry a quantization config")
if index.get("metadata", {}).get("total_size") != 55_562_855_904:
    raise SystemExit("unexpected indexed tensor bytes")
if len(index.get("weight_map", {})) != 1_199:
    raise SystemExit("unexpected indexed tensor count")

marker = root / ".download-complete"
temporary = root / ".download-complete.tmp"
temporary.write_text(f"{repo}@{revision}\n")
os.replace(temporary, marker)
print(f"verified {len(records)} records; DOWNLOAD_COMPLETE")
PY
chmod 600 /tmp/qwen38-27b-blackfrost-abliterated-bf16-download.py

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$DEST:$DEST" \
  -v "$MANIFEST_FILE:/checkpoint.manifest:ro" \
  -v /tmp/qwen38-27b-blackfrost-abliterated-bf16-download.py:/download.py:ro \
  "${TOKEN_MOUNT[@]}" \
  "$PYTHON_IMAGE" \
  bash -ceu "pip install --no-cache-dir 'huggingface_hub==0.34.4'; export HF_HUB_DISABLE_XET=1; python /download.py '$REPO' '$REV' '$DEST' /checkpoint.manifest"

printf "Downloading in container '%s'. Follow with: docker logs -f %s\n" "$NAME" "$NAME"
printf "Completion marker: %s/.download-complete\n" "$DEST"
