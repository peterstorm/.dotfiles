#!/usr/bin/env bash
# Download and verify Qwen3.8-Flash-Next-FP8 (172.82 GiB) without mutable refs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="Qwen/Qwen3.8-Flash-Next-FP8"
REV="970c569adaca6b35532111fd6b27351b2baefe50"
DEST="${DEST:-/models/Qwen3.8-Flash-Next-FP8-v1}"
MANIFEST_FILE="$SCRIPT_DIR/qwen38-flash-next-fp8-v1.manifest"
MANIFEST_SHA256="7d02680af7388f69f23d78a5db2e2c9f5bc536ba7a6b264068a9b2bb6b85157e"
PYTHON_IMAGE="python:3.12.11-slim-bookworm@sha256:519591d6871b7bc437060736b9f7456b8731f1499a57e22e6c285135ae657bf7"
NAME="qwen38-flash-next-fp8-v1-model-dl"

if [ "$(sha256sum "$MANIFEST_FILE" | cut -d' ' -f1)" != "$MANIFEST_SHA256" ]; then
  echo "error: checked-in Flash-Next manifest identity does not match" >&2
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

cat > /tmp/qwen38-flash-next-fp8-v1-download.py <<'PY'
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
quant = config.get("quantization_config", {})
if config.get("architectures") != ["Qwen4ExpForConditionalGeneration"]:
    raise SystemExit("unexpected Flash-Next architecture")
if config.get("model_type") != "qwen4_exp" or text.get("model_type") != "qwen4_exp_text":
    raise SystemExit("unexpected Flash-Next model type")
expected_text = {
    "max_position_embeddings": 262_144,
    "num_hidden_layers": 48,
    "num_experts": 512,
    "num_experts_per_tok": 10,
    "ngram_size": 3,
    "ngram_vocab_size_base": 20_000_000,
    "split_ngram_parts": 128,
    "heads_per_ngram": 8,
    "ple_embed_dim": 2560,
    "mtp_num_hidden_layers": 1,
}
if any(text.get(key) != value for key, value in expected_text.items()):
    raise SystemExit("unexpected Flash-Next text architecture contract")
if text.get("ple_layer_ids") != [2]:
    raise SystemExit("unexpected PLE layer placement")
if quant.get("quant_method") != "fp8" or quant.get("activation_scheme") != "dynamic":
    raise SystemExit("unexpected FP8 quantization contract")
if quant.get("weight_block_size") != [128, 128]:
    raise SystemExit("unexpected FP8 block size")
weight_map = index.get("weight_map", {})
if index.get("metadata", {}).get("total_size") != 185_502_232_570:
    raise SystemExit("unexpected indexed tensor bytes")
if len(weight_map) != 152_089:
    raise SystemExit("unexpected indexed tensor count")
ngram_prefix = "model.language_model.layers.1.ple.ple_embedding.ngram_embedding.shard_"
ngram_shards = {
    int(name.removeprefix(ngram_prefix).removesuffix(".weight"))
    for name in weight_map
    if name.startswith(ngram_prefix) and name.endswith(".weight")
}
if ngram_shards != set(range(128)):
    raise SystemExit("unexpected 128-way N-gram embedding sharding")
if not (root / "LICENSE").read_text().startswith("Qwen Community License 1.0"):
    raise SystemExit("unexpected checkpoint license")

marker = root / ".download-complete"
temporary = root / ".download-complete.tmp"
temporary.write_text(f"{repo}@{revision}\n")
os.replace(temporary, marker)
print(f"verified {len(records)} records; DOWNLOAD_COMPLETE")
PY
chmod 600 /tmp/qwen38-flash-next-fp8-v1-download.py

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --network host \
  -v "$DEST:$DEST" \
  -v "$MANIFEST_FILE:/checkpoint.manifest:ro" \
  -v /tmp/qwen38-flash-next-fp8-v1-download.py:/download.py:ro \
  "${TOKEN_MOUNT[@]}" \
  "$PYTHON_IMAGE" \
  bash -ceu "pip install --no-cache-dir 'huggingface_hub[hf_xet]==0.34.4'; export HF_XET_HIGH_PERFORMANCE=1; python /download.py '$REPO' '$REV' '$DEST' /checkpoint.manifest"

printf "Downloading in container '%s'. Follow with: docker logs -f %s\n" "$NAME" "$NAME"
printf "Completion marker: %s/.download-complete\n" "$DEST"
