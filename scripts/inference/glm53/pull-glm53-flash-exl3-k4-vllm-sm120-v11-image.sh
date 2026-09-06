#!/usr/bin/env bash
# Build and prove the GLM-5.3 v11 image: our pinned v84 base plus the legend
# upstream-core-port r2 overlay (native FP8 KV + ~90 engine/kernel fixes).
#
# Lineage: v9/v10 and the legend fork build on the SAME digest-pinned base, so
# v11 is not a patch on top of v10 — it replaces our v9/v10 patch series with
# the upstream-core port, which owns the same engine core, worker chain, b12x
# MLA kernels and model-side files. Both stacks implement a 528-byte FP8 MLA
# record; v11 keeps the upstream one (GLM_NOPE traits, capture-safe Triton
# writer, width authority) because it arrives with the rest of the fix set.
set -euo pipefail

BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
DERIVED_TAG="peterstorm/vllm:glm53-v11-upstream-core-port-r2"
UPSTREAM_REPO="https://github.com/legend/glm-5.3-flash-exl3-4bpw"
UPSTREAM_COMMIT="e65b2012d4ead12c86bd03f7e435ebace3ed3ae2"
OVERLAY_SHA256="c5cef15c27e3d638ba3a77dda522f877786de7c250d2ffb21e9373408cf48c26"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v11-image.identity}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-v11-upstream-core-port"
OVERLAY_ARCHIVE="$OVERLAY_DIR/upstream-core-port-$UPSTREAM_COMMIT.tar.gz"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}
for command in docker jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to build and prove the image" >&2
    exit 1
  }
done

actual_overlay_sha256="$(sha256sum "$OVERLAY_ARCHIVE" | cut -d' ' -f1)"
[ "$actual_overlay_sha256" = "$OVERLAY_SHA256" ] || {
  echo "error: vendored upstream-core-port archive is $actual_overlay_sha256, expected $OVERLAY_SHA256" >&2
  exit 1
}

# The overlay archive is the only source of engine/kernel code in this build;
# the Dockerfile must consume exactly it and the pinned base.
grep -Fq "FROM $BASE_IMAGE" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v11 Dockerfile does not build on the pinned base image" >&2
  exit 1
}
grep -Fq "upstream-core-port-$UPSTREAM_COMMIT.tar.gz" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v11 Dockerfile does not consume the pinned overlay archive" >&2
  exit 1
}

docker pull "$BASE_IMAGE" >/dev/null
actual_base_id="$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')"
[ "$actual_base_id" = "$BASE_ID" ] || {
  echo "error: pinned base image config is $actual_base_id, expected $BASE_ID" >&2
  exit 1
}

# The build is CPU-only: archive extraction, a manifest-driven install whose
# replacement/addition counts are pinned, and a byte-compile of every python
# destination. It fails closed on any manifest, count, or compile drift.
docker build --tag "$DERIVED_TAG" "$OVERLAY_DIR"

derived_id="$(docker image inspect "$DERIVED_TAG" --format '{{.Id}}')"
overlay_label="$(docker image inspect "$DERIVED_TAG" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.overlay-sha256"}}')"
[ "$overlay_label" = "$OVERLAY_SHA256" ] || {
  echo "error: built image records overlay $overlay_label, expected $OVERLAY_SHA256" >&2
  exit 1
}

# Prove the served tree actually carries the r2 work rather than the base's.
docker run --rm --entrypoint /opt/venv/bin/python "$DERIVED_TAG" - <<'PY'
import pathlib
import sys

root = pathlib.Path("/opt/infernal-invocation")
sparse = (root / "vllm/vllm/v1/attention/backends/mla/b12x_mla_sparse.py").read_text()
kernel = (root / "b12x/b12x/attention/_shared/mla/kernel.py").read_text()
interface = (root / "vllm/vllm/v1/kv_cache_interface.py").read_text()

checks = {
    "native FP8 KV gate": 'VLLM_B12X_FP8_KV' in sparse,
    "528B NoPE record": '_GLM_NOPE_FP8_KV_RECORD_BYTES = 528' in sparse,
    "FP8 gate reaches the cache interface": 'VLLM_B12X_FP8_KV' in interface,
    "b12x record-walk view stride": 'view.stride(' in kernel or 'stride(0)' in kernel,
    "new upstream dcp ops module": (root / "vllm/vllm/v1/attention/ops/dcp.py").is_file(),
    "new kv cache layout module": (root / "vllm/vllm/v1/kv_cache_layout.py").is_file(),
    "multimodal chat template": pathlib.Path("/opt/glm53/chat_template.multimodal.jinja").is_file(),
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    sys.exit(1)
print("V11 IMAGE CONTENT PROOF: r2 overlay is live in the served tree")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.v11-identity.XXXXXX")"
{
  printf 'base_index=%s\n' "$BASE_INDEX"
  printf 'base_image=%s\n' "$BASE_IMAGE"
  printf 'base_id=%s\n' "$BASE_ID"
  printf 'derived_tag=%s\n' "$DERIVED_TAG"
  printf 'derived_id=%s\n' "$derived_id"
  printf 'upstream_repo=%s\n' "$UPSTREAM_REPO"
  printf 'upstream_commit=%s\n' "$UPSTREAM_COMMIT"
  printf 'overlay_sha256=%s\n' "$OVERLAY_SHA256"
  printf 'model_rev=%s\n' "$MODEL_REV"
} >"$identity_tmp"
chmod 600 "$identity_tmp"
mv -f "$identity_tmp" "$IDENTITY_FILE"

printf 'GLM-5.3 v11 image built: %s\n' "$derived_id"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'Record this image id in run-glm53-flash-exl3-k4-vllm-sm120-v11.sh before serving.\n'
