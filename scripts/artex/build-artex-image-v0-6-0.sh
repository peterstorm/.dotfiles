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

# The audited identity. ARTX_EXPECTED_TAG/ARTX_EXPECTED_SHA exist so the
# regression test can point the same assert block at fixture repos; unset
# (every real invocation, including the workflow) they are exactly these.
TAG="${ARTX_EXPECTED_TAG:-v0.6.0}"
FULL="${ARTX_EXPECTED_SHA:-a13c68cb7078d43b66fb398db3d610e513b6d77a}"
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
# A failed probe is NOT a clean answer: capture the status and fail loudly,
# or a corrupt/stale index would silently pass the bond (the -z "" inversion).
status_out="$(git -C "$SRC" status --porcelain 2>/dev/null)" || {
  echo "FAIL: cannot verify $SRC is clean: git status failed" >&2
  exit 1
}
[ -z "$status_out" ] || { echo "FAIL: $SRC has uncommitted changes" >&2; exit 1; }
echo "provenance: $SRC @ $actual_tag ($actual_sha) = the audited checkout"
# Test seam: the regression test runs exactly this assert block, no docker.
if [ "${ARTX_ASSERT_ONLY:-0}" = "1" ]; then exit 0; fi

command -v docker >/dev/null 2>&1 || { echo "FAIL: docker not found" >&2; exit 1; }

# --- build (the audited Dockerfile: web -> go build -> tools -> runtime) ----
echo "== docker build $LOCAL_IMAGE =="
docker build --build-arg ARTEX_VERSION="$actual_tag" -t "$LOCAL_IMAGE" "$SRC"

# --- verify: the binary carries the audited version stamp (ldflags
# -X main.version, the same flags as the release binaries job — build.sh
# strips the leading v, so the expected string is the tag minus v; there is
# no -version flag to call).
echo "== verify =="
expected_stamp="${TAG#v}"
stamp_pattern="$(printf '%s' "$expected_stamp" | sed 's/[.]/\\./g')"
# Capture with the pipeline's failure neutralized: under pipefail the raw
# assignment would exit before the guard below could print its diagnostic.
stamp="$(docker run --rm --entrypoint /bin/sh "$LOCAL_IMAGE" \
  -c "grep -a -o -- '$stamp_pattern' /app/artex" | head -1 || true)"
[ "$stamp" = "$expected_stamp" ] || { echo "FAIL: binary does not carry the $expected_stamp stamp (got: ${stamp:-none})" >&2; exit 1; }
echo "binary stamp: $stamp"
# The toolbox gate: one probe per tool. Multi-operand `command -v` exits 0
# even when operands are missing, so a partially failed tool install must be
# caught per tool, by name.
toolbox_missing="$(docker run --rm --entrypoint /bin/sh "$LOCAL_IMAGE" \
  -c 'for t in nuclei httpx subfinder katana ffuf dalfox sqlmap bbot; do
        command -v "$t" >/dev/null 2>&1 || echo "$t"
      done')" || { echo "FAIL: scanner toolbox probe failed" >&2; exit 1; }
[ -z "$toolbox_missing" ] || { echo "FAIL: scanner toolbox incomplete, missing: $(printf '%s ' $toolbox_missing)" >&2; exit 1; }
echo "toolbox: all present"

echo "done: $LOCAL_IMAGE"
