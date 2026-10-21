#!/usr/bin/env bash
# Static release contract for DeepSeek-V4.1-Flash-1017 on Project Maya
# (LibertAIDAI EXL3 3.5 bpw + DeepSeek's Engram tables, profile
# ds41-1017-maya-exl35).
#
# Proves, without Docker or a GPU, that the download/run/switch scripts pin
# the toolchain image, the Maya commit and the vendored manifest; that the
# manifest is the 1017 checkpoint's EXL3 3.5 bpw with every file sized and
# hashed and the Engram tables from DeepSeek's 1017 base repo; that the
# storage, catalog and key handling are wired the way the runbook says; and
# that the switcher keeps the transactional shape.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/scripts/inference/deepseek/ds41-1017-maya"
DL="$DIR/download-ds41-1017-maya-exl35.sh"
RUN="$DIR/run-ds41-1017-maya-exl35.sh"
SWITCH="$DIR/switch-ds41-1017-maya-exl35.sh"
MANIFEST="$DIR/download-3.5bpw.json"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
DISKS="$ROOT/machines/desktop/disks.nix"
RUNBOOK="$ROOT/docs/runbooks/ds41-1017-maya-exl35-runbook-2026-10-21.md"

MANIFEST_SHA256="b30489b0462cab55b1b9a522b7b8d8134325db9d11b5f7caee07707fd84c8ace"
MAYA_COMMIT="8d9a9b5d705049a87da853717cdc59440252de30"
IMAGE_CONFIG="sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a"
IMAGE_DIGEST="sha256:495b340eede3bbb348fd6c9662d1535e0d2f27e47c08cc71802fea6bc68caf40"
REPO="LibertAIDAI/DeepSeek-V4.1-Flash-1017-EXL3-3.5bpw"
REVISION="04a492fc3b4d25ddbab8f2d2f07f235ec77c9010"
ENGRAM_REPO="deepseek-ai/DeepSeek-V4.1-Flash-1017"
ENGRAM_REVISION="1bae0e1088993b9b82de08f59de5be5a34e42170"
WEIGHT_BYTES="257641444616"
ENGRAM_BYTES="203073077576"
TOTAL_BYTES="460714522192"
CONTAINER="ds41-1017-maya-exl35"
SERVED_MODEL="deepseek-v4.1-flash"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}
lacks() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then echo "FAIL: $file must not contain $text" >&2; exit 1; fi
}

for file in "$DL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done
[ -r "$RUNBOOK" ] || { echo "FAIL: runbook is missing" >&2; exit 1; }

# --- the vendored manifest is Maya's, and is the 1017 EXL3 3.5 bpw ----------
actual="$(sha256sum "$MANIFEST" | cut -d' ' -f1)"
[ "$actual" = "$MANIFEST_SHA256" ] || { echo "FAIL: manifest digest $actual, expected $MANIFEST_SHA256" >&2; exit 1; }
jq -e --arg repo "$REPO" --arg rev "$REVISION" --arg erepo "$ENGRAM_REPO" --arg erev "$ENGRAM_REVISION" \
  --argjson wb "$WEIGHT_BYTES" --argjson eb "$ENGRAM_BYTES" '
  def pinned: all(to_entries[]; (.value[0] > 0) and (.value[1] | test("^[0-9a-f]{64}$")));
  .repo == $repo and .revision == $rev
  and (.files | length) == 54 and ([.files[] | .[0]] | add) == $wb and (.files | pinned)
  and .engram.repo == $erepo and .engram.revision == $erev
  and (.engram.files | keys) == ["model-00047-of-00048.safetensors", "model-00048-of-00048.safetensors"]
  and ([.engram.files[] | .[0]] | add) == $eb and (.engram.files | pinned)
  and ((.files | keys) - (.engram.files | keys)) == (.files | keys)
' "$MANIFEST" >/dev/null || { echo "FAIL: manifest is not the pinned 1017 EXL3 3.5 bpw" >&2; exit 1; }

# --- download script: pinned manifest, both repos, verified files, durable unit
contains "$DL" "MANIFEST_SHA256=\"$MANIFEST_SHA256\""
contains "$DL" "MAYA_COMMIT=\"$MAYA_COMMIT\""
contains "$DL" 'FILE_COUNT=56'
contains "$DL" "TOTAL_BYTES=$TOTAL_BYTES"
contains "$DL" 'DEST="$MODELS_DIR/DeepSeek-V4.1-Flash-1017-3.5bpw"'
contains "$DL" 'sha256sum -c --quiet - || die "manifest does not match the pinned sha256"'
contains "$DL" 'mountpoint -q "$MODELS_DIR"'
contains "$DL" '([$w, .], [$e, .engram]) as [$dir, $src]'
contains "$DL" 'ENGRAM_DEST="$MODELS_DIR/engram"'
contains "$DL" 'mountpoint -q "$ENGRAM_DEST"'
contains "$DL" 'ln -sfn "$dir/$name" "$DEST/$name"'
contains "$DL" 'https://huggingface.co/$repo/resolve/$rev/$name'
contains "$DL" '-C - -o "$out"'
contains "$DL" 'sha256 mismatch $name'
contains "$DL" '.download-complete'
contains "$DL" 'sudo systemd-run --unit "$UNIT" --collect --uid "$(id -u)"'
lacks "$DL" 'resolve/main'

# --- run script: pins, gates, key never on a command line ------------------
contains "$RUN" "IMAGE_CONFIG=\"$IMAGE_CONFIG\""
contains "$RUN" "IMAGE_DIGEST=\"$IMAGE_DIGEST\""
contains "$RUN" "MAYA_COMMIT=\"$MAYA_COMMIT\""
contains "$RUN" 'endswith("@" + $d)'
contains "$RUN" 'git -C "$MAYA_DIR" status --porcelain'
contains "$RUN" '(.archs | index(120)) and (.targets | index("maya-ds4"))'
contains "$RUN" 'QUANT="exl3-3.5"'
contains "$RUN" 'QUANT_DIR="$MODELS_DIR/DeepSeek-V4.1-Flash-1017-3.5bpw"'
contains "$RUN" '.installer.ds4_quant == $q'
contains "$RUN" "--ds4-quant '\$QUANT'"
contains "$RUN" "NAME=\"$CONTAINER\""
contains "$RUN" "SERVED_MODEL=\"$SERVED_MODEL\""
contains "$RUN" 'PORT=8000'
contains "$RUN" '--restart no'
contains "$RUN" '-e MAYA_UPDATE_CHECK=0'
contains "$RUN" '--ulimit memlock=-1'
contains "$RUN" 'comfyui.service is active'
contains "$RUN" 'gpuPowerLimitWatts'
contains "$RUN" 'memory_used <= 1024'
contains "$RUN" 'inference_prepare_api_key'
contains "$RUN" 'STRATA_API_KEY=$INFERENCE_API_KEY'
contains "$RUN" '--env-file "$ENVFILE"'
lacks "$RUN" '--api-key'
lacks "$RUN" 'gguf-q8'

# --- switcher: idle gate, exact model, receipt, promotion, rollback ---------
contains "$SWITCH" "TARGET=\"$CONTAINER\""
contains "$SWITCH" "EXPECTED_MODEL=\"$SERVED_MODEL\""
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'require_idle_endpoint'
contains "$SWITCH" '.status == "ok" and .unloaded == false'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'report_boot_receipt'
contains "$SWITCH" 'docker update --restart=unless-stopped "$TARGET"'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'restore_profiles "${stopped[@]}"'

# --- catalog and storage ----------------------------------------------------
contains "$CATALOG" "  $CONTAINER"
lacks "$CATALOG" "  ds41-1017-maya-q8"
contains "$DISKS" '"models/ds41" = {'
contains "$DISKS" 'mountpoint = "/models/ds41";'
contains "$DISKS" 'primarycache = "metadata";'
contains "$DISKS" '"models/ds41/engram" = {'
contains "$DISKS" 'recordsize = "16K";'
contains "$DISKS" 'primarycache = "all";'

# --- runbook names the same identities --------------------------------------
for fact in "$MAYA_COMMIT" "${IMAGE_CONFIG#sha256:}" "${IMAGE_DIGEST#sha256:}" "$REVISION" "$ENGRAM_REVISION" \
  "$SERVED_MODEL" "$CONTAINER" "primarycache=metadata"; do
  contains "$RUNBOOK" "$fact"
done

echo "ds41-1017-maya-exl35 contract: PASS"
