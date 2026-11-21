#!/usr/bin/env bash
# Static release contract for GLM-5.3 full on ds4-native (scripts/inference/glm53/glm53-native).
#
# Three primaries serve GLM-5.3 full (753B, kitaniai's MXFP4 Experts) on ds4-native's GLM engine
# behind Project Maya's server, one Backbone each: glm-native (zai's stock), uncensored-native
# (dealignai's UNCENSORED surgery, kitaniai's Backbone A), cyber-native (dealignai's CYBERSECURITY).
# The contract proves, without Docker or a GPU, that the launcher pins its engine, checkpoint,
# Backbones and server; that its weights table is exactly the three Backbones with their served ids;
# that it refuses bad settings before any I/O; that it shares the DS4.1 launcher's patched Maya
# server; and that the switcher, the profile catalog, Pi's catalog and the runbook all carry the
# same names and context.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/glm53/glm53-native/run-glm53-native.sh"
DS41_RUN="$ROOT/scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh"
SWITCH="$ROOT/scripts/inference/switch-primary.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/scripts/inference/runbooks/glm53-native-runbook-2026-11-21.md"
INDEX="$ROOT/scripts/inference/INDEX.md"

CONTAINER="glm53-native"
SERVED_MODEL="glm-5.3-uncensored-native"
CYBER_SERVED_MODEL="glm-5.3-cyber-native"
STOCK_SERVED_MODEL="glm-5.3-native"
CHECKPOINT_SOURCE="kitaniai/GLM-5.3-UNCENSORED-MXFP4@559df987aa258cad0395f9749d27915e235b970a"
CYBER_SOURCE="dealignai/GLM-5.3-CYBERSECURITY-FP8@5915c1b88f998a9c1e1a0c83688e285a08ae3ca5"
STOCK_SOURCE="zai-org/GLM-5.3-BF16@abf42e6c0e53bc29a875511301e7b7fcd220315b"
CONTEXT=65536
# primary  weights  served id: the switcher's three GLM-5.3 full primaries.
GLM_PRIMARIES="glm-native stock $STOCK_SERVED_MODEL
uncensored-native uncensored $SERVED_MODEL
cyber-native cyber $CYBER_SERVED_MODEL"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "${1#"$ROOT"/} is missing: $2"; }

for file in "$RUN" "$RUNBOOK"; do
  [ -f "$file" ] || fail "missing ${file#"$ROOT"/}"
done
[ -x "$RUN" ] || fail "${RUN#"$ROOT"/} is not executable"
bash -n "$RUN"

# The engine by full commit, the server by commit (the DS4.1 launcher's, so one patched copy serves both).
grep -Eq '^DS4N_COMMIT="\$\{DS4N_COMMIT:-[0-9a-f]{40}\}"$' "$RUN" || fail "DS4N_COMMIT must default to a full 40-hex commit"
maya_of() { sed -n 's/^MAYA_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "$1"; }
[ -n "$(maya_of "$RUN")" ] || fail "MAYA_COMMIT must be a full 40-hex commit"
[ "$(maya_of "$RUN")" = "$(maya_of "$DS41_RUN")" ] || fail "MAYA_COMMIT differs from the DS4.1 launcher's: two Maya installs would compete"
contains "$RUN" 'MAYA_PATCH="$SCRIPT_DIR/../../deepseek/ds41-1017-native/maya-serve-keepalive.patch"'
contains "$RUN" 'MAYA_SERVE="/models/ds41/native/maya-${MAYA_COMMIT:0:12}-$(sha256sum "$MAYA_PATCH" | cut -c1-12)"'
contains "$DS41_RUN" 'MAYA_SERVE="$NATIVE/maya-${MAYA_COMMIT:0:12}-$(sha256sum "$MAYA_PATCH" | cut -c1-12)"'
contains "$RUN" "CHECKPOINT_SOURCE=\"$CHECKPOINT_SOURCE\""

# The weights table: exactly three Backbones, each with its source and served id; uncensored the default.
# One arm of the launcher's case: the lines from "  LABEL)" through its ";;".
weights_arm() { sed -n "/^  $1)\$/,/^    ;;\$/p" "$RUN"; }
contains "$RUN" 'WEIGHTS="${WEIGHTS:-uncensored}"'
[ "$(sed -n 's/^  \([a-z]*\))$/\1/p' "$RUN" | paste -sd' ')" = "uncensored cyber stock" ] ||
  fail "the weights table must be exactly uncensored, cyber and stock"
[ "$(weights_arm stock)" = "  stock)
    BACKBONE=\"\$STORE_DIR/backbone-stock\"
    BACKBONE_SOURCE=\"$STOCK_SOURCE\"
    SERVED_MODEL=\"$STOCK_SERVED_MODEL\"
    ;;" ] || fail "WEIGHTS=stock must serve the stock Backbone as $STOCK_SERVED_MODEL"
[ "$(weights_arm uncensored)" = '  uncensored)
    BACKBONE="$STORE_DIR/backbone-uncensored"
    BACKBONE_SOURCE="$CHECKPOINT_SOURCE"
    SERVED_MODEL="glm-5.3-uncensored-native"
    ;;' ] || fail "WEIGHTS=uncensored must serve Backbone A as $SERVED_MODEL"
[ "$(weights_arm cyber)" = "  cyber)
    BACKBONE=\"\$STORE_DIR/backbone-cyber\"
    BACKBONE_SOURCE=\"$CYBER_SOURCE\"
    SERVED_MODEL=\"$CYBER_SERVED_MODEL\"
    ;;" ] || fail "WEIGHTS=cyber must serve the cyber Backbone as $CYBER_SERVED_MODEL"
# Provenance is checked at every launch, not only at install.
contains "$RUN" "die \"\$BACKBONE does not hold the 88 Backbone parts\""
contains "$RUN" '[ "$(jq -r '"'"'.base | split("/") | last'"'"' "$BACKBONE/VARIANT.json")" = backbone-uncensored ]'

# Settings: the owner's defaults, and refusals before any I/O (exit 2, no docker, no GPU).
contains "$RUN" "CONTEXT=\"\${CONTEXT:-$CONTEXT}\""
contains "$RUN" 'LAMBDA="${LAMBDA:-0.03}"'
contains "$RUN" 'REASONING_EFFORT="${REASONING_EFFORT:-high}"'
contains "$RUN" 'THINKING_BUDGET="${THINKING_BUDGET:-8192}"'
refused() { # ENV... -- ARGS: the launcher exits 2
  local rc=0 env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  env "${env[@]}" bash "$RUN" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "run-glm53-native.sh ${env[*]} $* must exit 2 before any I/O (got $rc)"
}
refused WEIGHTS=bogus -- --preflight
refused CONTEXT=1024 -- --preflight
refused CONTEXT=64k -- --preflight
refused LAMBDA=1.5 -- --preflight
refused LAMBDA=-0.1 -- --preflight
refused CHECKPOINT_GB=4.5 -- --preflight
refused REASONING_EFFORT=xhigh -- --preflight
refused WEIGHTS=uncensored -- --bogus

# Serving: one profile on the GPUs, the RAM tier alone with the host's memory, back at boot only once healthy.
contains "$RUN" "NAME=\"$CONTAINER\""
contains "$RUN" 'comfyui.service is active'
contains "$RUN" "others=\"\$(docker ps --filter name='^glm53-' --format '{{.Names}}')\""
contains "$RUN" 'docker run -d --name "$NAME" --restart no'
contains "$RUN" 'docker update --restart=unless-stopped "$NAME"'
contains "$RUN" '--label ai.peterstorm.inference.served-model="$SERVED_MODEL"'
contains "$RUN" '--ulimit memlock=-1 --security-opt seccomp=unconfined'
contains "$RUN" '"--ram-per-layer", "auto", "--ram-reserve-gib", $reserve, "--checkpoint-gb", $ckpt'
contains "$RUN" 'source "$SCRIPT_DIR/../../shared/inference-api-key.sh"'

# The switcher, the profile catalog (Hyperflare's switcher quiesces and restores it) and Pi's catalog.
contains "$SWITCH" "GLM_NATIVE_CONTAINER=\"$CONTAINER\""
contains "$SWITCH" 'GLM_NATIVE_RUN="$SCRIPT_DIR/glm53/glm53-native/run-glm53-native.sh"'
contains "$SWITCH" 'glm-native | uncensored-native | cyber-native) WEIGHTS="$(weights_of_primary "$1")" "$GLM_NATIVE_RUN" --launch ;;'
contains "$SWITCH" 'glm-native | uncensored-native | cyber-native) "$GLM_NATIVE_RUN" --stop ;;'
contains "$CATALOG" "  $CONTAINER"
# Each primary's Backbone and served id agree across the switcher, the launcher's table and Pi's catalog.
while read -r primary weights served; do
  contains "$SWITCH" "$primary) echo $weights ;;"
  contains "$SWITCH" "$primary) echo $served ;;"
  weights_arm "$weights" | grep -Fxq "    SERVED_MODEL=\"$served\"" || fail "WEIGHTS=$weights must serve $served"
  jq -e --arg id "$served" --argjson ctx "$CONTEXT" '
    .providers["desktop-vllm"].models
    | map(select(.id == $id))
    | length == 1 and .[0].contextWindow == $ctx and .[0].input == ["text"]
  ' "$PI_MODELS" >/dev/null || fail "pi/models.json does not carry $served with the launcher's $CONTEXT context, text only"
done <<<"$GLM_PRIMARIES"

# The runbook and the index record it.
contains "$RUNBOOK" "$(sed -n 's/^DS4N_COMMIT="\${DS4N_COMMIT:-\([0-9a-f]\{12\}\).*/\1/p' "$RUN")"
contains "$RUNBOOK" 'λ 0.03'
contains "$RUNBOOK" 'CHECKPOINT_GB'
while read -r primary weights served; do
  contains "$RUNBOOK" "switch-primary.sh $primary"
  contains "$RUNBOOK" "WEIGHTS=$weights"
  contains "$INDEX" "| \`$primary\` | \`$served\` |"
done <<<"$GLM_PRIMARIES"
contains "$INDEX" 'glm53-native-runbook-2026-11-21.md'

echo "GLM-5.3 ds4-native contract: PASS"
