#!/usr/bin/env bash
# Build the ARTEX pentest-harness image from the audited upstream checkout.
# Runs locally AND under .github/workflows/build-artex-image.yml (which adds
# the GHCR login + tag/publish steps — this script stays publish-agnostic).
#
# The audit bond (2026-11-15 planted-code/backdoor audit): the source is
# pinned to the audited tag AND full SHA, and the worktree must be clean —
# "image ≠ audited source" is unrepresentable. The binary is stamped with the
# same version the release binaries job uses.
#
# Security posture (the CERT-In lesson, institutionalized): no Docker Hub
# artex images — the only foreign inputs are the audited Dockerfile's own
# bases (node:22, golang:1.26, debian, python) with checksum-verified scanner
# and node-tarball downloads.
#
# Usage:
#   # under Actions (fresh clone into ./artex-src):
#   bash scripts/artex/build-artex-image-v0-6-0.sh
#   # locally, from the audited checkout:
#   ARTX_SRC=~/dev/artex/src bash scripts/artex/build-artex-image-v0-6-0.sh
set -euo pipefail

TAG="v0.6.0"
FULL="a13c68cb7078d43b66fb398db3d610e513b6d77a"
SHORT="a13c68cb"
LOCAL_IMAGE="peterstorm/artex:sha-$SHORT"
SRC="${ARTX_SRC:-$PWD/artex-src}"

# --- provenance: the audit bond --------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet --branch "$TAG" https://github.com/BaaRai/ARTEX "$SRC"
fi
actual_tag="$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || true)"
actual_sha="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
[ "$actual_tag" = "$TAG" ]  || { echo "FAIL: $SRC is not exactly at $TAG (got: ${actual_tag:-none})" >&2; exit 1; }
[ "$actual_sha" = "$FULL" ] || { echo "FAIL: $SRC HEAD is $actual_sha, expected $FULL" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain 2>/dev/null)" ] || { echo "FAIL: $SRC has uncommitted changes" >&2; exit 1; }
echo "provenance: $SRC @ $actual_tag ($actual_sha) = the audited checkout"

command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found" >&2; exit 1; }

# --- build (the audited Dockerfile: web -> go build -> tools -> runtime) ----
echo "== docker build $LOCAL_IMAGE =="
docker build --build-arg ARTEX_VERSION="$actual_tag" -t "$LOCAL_IMAGE" "$SRC"

# --- verify: the binary carries the audited version stamp (ldflags
# -X main.version, the same flags as the release binaries job — and build.sh
# strips the leading v, so the string is 0.6.0, not v0.6.0; there is no
# -version flag to call). The image's own RUN steps already verify the
# scanner toolbox (nuclei/httpx/... -version) --
echo "== verify =="
stamp="$(docker run --rm --entrypoint /bin/sh "$LOCAL_IMAGE" \
  -c "grep -a -m1 -o '0\\.6\\.0' /app/artex" || true)"
[ "$stamp" = "0.6.0" ] || { echo "FAIL: binary does not carry the 0.6.0 stamp (got: ${stamp:-none})" >&2; exit 1; }
echo "binary stamp: $stamp"
docker run --rm --entrypoint /bin/sh "$LOCAL_IMAGE" \
  -c 'command -v nuclei httpx subfinder katana ffuf dalfox sqlmap bbot' | sort

echo "done: $LOCAL_IMAGE"
