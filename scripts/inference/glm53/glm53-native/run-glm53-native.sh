#!/usr/bin/env bash
# GLM-5.3 full (753B: kitaniai's GLM-5.3-UNCENSORED-MXFP4 Experts, which no CRACK surgery touches, and
# one of three Backbones: zai's stock, dealignai's UNCENSORED, dealignai's CYBERSECURITY) on ds4-native
# (peterstorm/ds4-native, main since 090ccf0; the GLM engine under src/*/glm53): the MXFP4 Experts streamed from the NVMe into a VRAM Expert cache and a
# pinned RAM tier on the two RTX PRO 6000s, the dense Backbone resident, behind Project Maya's
# OpenAI-compatible server. Served on :8000 like every other profile, with the shared inference key.
#
# Maya's server (serve/server.py, MIT, at the pinned commit of the Maya checkout) renders the chat with
# GLM-5's template (its serve/glm5_chat_template.jinja: past reasoning kept, so a next turn is an
# append), tokenizes, parses tool calls and streams; it starts `ds4n-glm53-serve --serve ARGS` and
# speaks Maya's engine protocol with it over stdin/stdout (GEN / T / DONE). One request at a time:
# requests beyond it wait in the server's line, each kept alive while it waits.
#
# Requests from any conversation it keeps: a chat's next turn and an agent's next step read only their
# new tokens; a conversation another one displaced comes back from its KV checkpoint in host RAM
# (CHECKPOINT_GB of them, ~95 KB a token), bit-identical to reading it again (ds4n-glm53-serve-check).
#
# Speed (2026-11-21, measured through this server at 64K and λ 0.03; ds4-native
# docs/bench/glm53-serve/2026-11-21-serve.md): decode 6-7 tok/s (6.2 after a 4.5K-token prompt, 13%
# of its Expert reads missing VRAM and RAM); a long prompt's new tokens ~200 tok/s (4,519 in 22.9 s),
# a short one a few seconds whatever its length (a first 30-token chat: 14 s). Decode is bound by
# Expert reads from the NVMe (the 753B's routed Experts are 375 GiB; VRAM holds a quarter of them).
# That was 83 Slots a layer under LRU. Since 2026-11-22 (Cohorts, the Ledger, and the residency
# settings below) the engine opens 92 in a fitted shape under counter:55: ds4n-glm53-decode measured
# 7.95 tok/s at 64K and λ 0.03 (the frontier report). Since 2026-11-23 the engine's reads land on CUDA
# events (+1.8%, the same tokens) and reply tokens defer their low-ranked Misses one layer (DEFER, below):
# ds4n-glm53-decode measured 8.61 tok/s at equal reads against 7.92 without; served through this
# server, 8.50 (four 300-token chats, 2026-11-23). At this launcher's 202,752 context (74 Slots), the
# same chats: 6.84 (CONTEXT, below). Since the Latent split (2026-11-23, each GPU holds half the KV
# cache's Latent rows, bit-identical) 202,752 opens 86 Slots (CONTEXT, below).
#
# What the repository owns:
#   - the Backbone by source (WEIGHTS), checked against its provenance record at every launch;
#   - the image by name (ds4-native-dev:2: CUDA 13.4 + Python 3.12, the base Maya's .venv was made in);
#   - the engine by commit (DS4N_COMMIT): --install builds ds4n-glm53-serve from that commit of the
#     desktop's clone, runs the core tests, and writes the tokenizer in Maya's form from the checkpoint
#     (ds4-native tools/glm53-serve/write_tokenizer.py), checked id for id against HF `tokenizers`;
#   - the Maya server by commit (MAYA_COMMIT + maya-serve-keepalive.patch): the same patched copy the
#     DS4.1 launcher installs (keyed by commit and patch, so either launcher's install serves both);
#   - the engine's settings: context, λ, the eviction policy, the VRAM and RAM tiers' reserves, deferral,
#     checkpoints;
#   - the workstation gates: two idle RTX PRO 6000s, comfyui stopped, port 8000 free, no other glm53-*
#     container running (the RAM tier pins most of the host's memory: a CPU replay beside it once
#     wedged this host).
#
# Modes:
#   --preflight   check every pin without touching the GPUs
#   --install     build the pinned engine and the tokenizer (once per DS4N_COMMIT; GPUs not needed)
#   --launch      start the server container (default); returns once it serves, set to restart at boot
#   --stop        stop it (and so keep it down at boot)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../../shared/inference-profile-catalog.sh"

IMAGE="ds4-native-dev:2"
DS4N_COMMIT="${DS4N_COMMIT:-d398fae043df6e50e5023bb3d463b533d558591d}"
DS4N_SRC="${DS4N_SRC:-$HOME/dev/ds4-native}"
MAYA_COMMIT="b3fa99ec244e7885ec04ef456eac0d52474dba95"
MAYA_DIR="/models/ds41/project-maya"
MAYA_PATCH="$SCRIPT_DIR/../../deepseek/ds41-1017-native/maya-serve-keepalive.patch"
MAYA_SERVE="/models/ds41/native/maya-${MAYA_COMMIT:0:12}-$(sha256sum "$MAYA_PATCH" | cut -c1-12)"
GLM_DIR="/models/glm53-native"
CHECKPOINT="$GLM_DIR/kitaniai"           # config.json, tokenizer.json, chat_template.jinja (the shards are in the store)
CHECKPOINT_SOURCE="kitaniai/GLM-5.3-UNCENSORED-MXFP4@559df987aa258cad0395f9749d27915e235b970a"
STORE_DIR="/models/glm53-store"
STORE="$STORE_DIR/experts.ds4n"
SERVE_DIR="$GLM_DIR/serve"
ENGINE="$SERVE_DIR/bin/ds4n-glm53-serve-${DS4N_COMMIT:0:12}"
TOKENIZER="$SERVE_DIR/tokenizer"
CONFIG="$SERVE_DIR/glm53-native.json"
# Whose dense weights the Backbone carries; the routed Experts are kitaniai's in all three (the
# surgeries edit only o_proj and the shared Expert's down_proj, so the Experts are zai's own):
#   uncensored  kitaniai's own (dealignai's UNCENSORED surgery, Quark MXFP4): Backbone A. The default.
#   cyber       dealignai's GLM-5.3-CYBERSECURITY edits on Backbone A (124 tensors re-converted with
#               kitaniai's recipe, bit-exact on the weights both leave unedited; its VARIANT.json).
#   stock       zai's release: Backbone A with those 124 tensors from zai's BF16, quantized as the
#               surgeries' FP8 base was, then kitaniai's recipe (bit-exact on the 29 unedited weights).
WEIGHTS="${WEIGHTS:-uncensored}"
case "$WEIGHTS" in
  uncensored)
    BACKBONE="$STORE_DIR/backbone-uncensored"
    BACKBONE_SOURCE="$CHECKPOINT_SOURCE"
    SERVED_MODEL="glm-5.3-uncensored-native"
    ;;
  cyber)
    BACKBONE="$STORE_DIR/backbone-cyber"
    BACKBONE_SOURCE="dealignai/GLM-5.3-CYBERSECURITY-FP8@5915c1b88f998a9c1e1a0c83688e285a08ae3ca5"
    SERVED_MODEL="glm-5.3-cyber-native"
    ;;
  stock)
    BACKBONE="$STORE_DIR/backbone-stock"
    BACKBONE_SOURCE="zai-org/GLM-5.3-BF16@abf42e6c0e53bc29a875511301e7b7fcd220315b"
    SERVED_MODEL="glm-5.3-native"
    ;;
  *) echo "error: WEIGHTS is uncensored, cyber or stock: $WEIGHTS" >&2; exit 2 ;;
esac
# Positions every layer's KV cache holds: the context Maya reports (its dashboard reloads the engine
# with another). Since Cohorts (prompts swept 16K at a time, so the sweep's rows no longer scale with
# CONTEXT) and the Latent split (each GPU holds the Latent rows of half the positions; ds4-native
# docs/bench/glm53-split/2026-11-23-split-report.md) a position takes 51,488 B of VRAM a GPU (95,264
# before the split): 1K positions cost ~0.07 Slots per Sparse layer. At the 2.25 GiB reserve the
# Ledger opens 95 Slots a layer at 65,536 and 86 at 202,752 (74 before the split). The owner asked for
# more context (2026-11-23) and took 202,752: before the split it served 6.84 tok/s against 8.50 at
# 65,536 (−19.5%), and a 165,942-token prompt peaked at 95,166 MiB (ds4-native
# docs/bench/glm53-context/2026-11-23-context-cost.md); the split's engine runs measured +2% to +19%
# by conversation over that. The cap is this launcher's (GLM-5.3 allows 1M; the owner: 202,752 is
# enough for now); the engine opens 409,600 at 72 Slots.
CONTEXT="${CONTEXT:-202752}"
if ! [[ "$CONTEXT" =~ ^[0-9]+$ ]] || ((CONTEXT < 4096 || CONTEXT > 202752)); then
  echo "error: CONTEXT is 4096 to 202752: $CONTEXT" >&2
  exit 2
fi
# Cache-conditional routing for the reply's tokens (owner's choice 2026-11-20, "go with λ 0.03"): a
# resident Expert's router score gets +λ before the top-8, so fewer Experts are read from the NVMe;
# prompts route exactly. LAMBDA=0 serves the model's exact routing.
LAMBDA="${LAMBDA:-0.03}"
[[ "$LAMBDA" =~ ^0(\.[0-9]+)?$ ]] || { echo "error: LAMBDA is a number in [0, 1): $LAMBDA" >&2; exit 2; }
# The three residency settings below are the owner's brief of 2026-11-22 ("more speed at an acceptable
# quality loss"; ds4-native docs/bench/glm53-counter/2026-11-22-frontier-report.md). Together at λ
# 0.03: 7.95 tok/s pooled over four prompts against LRU's 6.91 at 90 equal Slots, KL 0.071 and top-1
# 89.6% against the exact model, the same quality class as LRU's (a residency change re-rolls some
# Routes; the paired test finds no shift). λ 0.035 and 0.04 were measured too and rejected.
#
# Which resident Expert a miss evicts: counter:55 keeps a use count per Expert, halved every 55
# tokens, and evicts the lowest; lru the least recently used. counter:55 decodes ~10% faster at λ
# 0.03 (90 Slots, four prompts) and changes only timing at λ 0.
EVICTION="${EVICTION:-counter:55}"
[[ "$EVICTION" =~ ^(lru|counter:[1-9][0-9]*)$ ]] || { echo "error: EVICTION is lru or counter:N: $EVICTION" >&2; exit 2; }
# VRAM each GPU keeps back for what the Ledger does not plan (CUDA's context, library workspaces): the
# rest of the card is Expert Slots. 2.25 GiB opens 92 Slots a layer at 64K (3.75 GiB, the engine's
# default, 90); serving a 39,200-token prompt at 92 peaked at 95,504 MiB, 1.7 GiB under the card, and a
# 165,942-token prompt at 202,752 (74 Slots) at 95,166 MiB.
RUNTIME_RESERVE_GIB="${RUNTIME_RESERVE_GIB:-2.25}"
[[ "$RUNTIME_RESERVE_GIB" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo "error: RUNTIME_RESERVE_GIB is a number of GiB: $RUNTIME_RESERVE_GIB" >&2; exit 2; }
# How the Ledger's Slots are spread over the 75 Sparse layers. fitted: in proportion above the 64-Slot
# floor to slot-profile-l0.03-counter55.txt (ds4-native --slot-profile; fitted offline on λ 0.03 Routes
# under counter:55, the late layers get more), so one profile serves any CONTEXT. Against equal Slots
# at 92 it misses VRAM 4% less at no measured KL (paired Δ +0.0003). It is that routing's shape only
# (at λ 0 the early layers want the most), so another λ or policy must set SLOT_SHAPE=equal.
SLOT_SHAPE="${SLOT_SHAPE:-fitted}"
case "$SLOT_SHAPE" in
  equal) SLOT_PROFILE="" ;;
  fitted)
    [ "$LAMBDA" = 0.03 ] && [ "$EVICTION" = counter:55 ] || {
      echo "error: SLOT_SHAPE=fitted was fitted for LAMBDA=0.03 and EVICTION=counter:55 (got $LAMBDA, $EVICTION): set SLOT_SHAPE=equal" >&2
      exit 2
    }
    SLOT_PROFILE="$(<"$SCRIPT_DIR/slot-profile-l0.03-counter55.txt")"
    ;;
  *) echo "error: SLOT_SHAPE is fitted or equal: $SLOT_SHAPE" >&2; exit 2 ;;
esac
# Deferral (owner, 2026-11-23: "go ahead with --defer 4"; ds4-native
# docs/bench/glm53-defer/2026-11-23-defer-report.md): a reply token's Expert that missed VRAM, outside its
# DEFER heaviest Route slots of 8, waits one Sparse layer, its read overlapping that layer's compute.
# At 4: +8.7% decode at equal reads, KL 0.0699 against λ 0.03's 0.0710 (paired: free), top-1 88.75%
# against 89.57% (−23 of 2,800 positions, p 0.15). 2 and 0 cost real quality (KL +11% / +81%). off
# serves without it. Prompts never defer (they are read as sweeps).
DEFER="${DEFER:-4}"
[[ "$DEFER" =~ ^(off|[0-8])$ ]] || { echo "error: DEFER is off or the protected Route slots, 0 to 8: $DEFER" >&2; exit 2; }
# Host memory: the RAM tier takes what is available at load less RAM_RESERVE_GIB and CHECKPOINT_GB.
# With the server loaded (~3 GB) the reserve stays free for the OS, ZFS's ARC (capped at 4 GiB) and
# the conversations set aside (~95 KB a token: 4 GB hold ~42K tokens of them).
RAM_RESERVE_GIB="${RAM_RESERVE_GIB:-10}"
CHECKPOINT_GB="${CHECKPOINT_GB:-4}"
[[ "$RAM_RESERVE_GIB" =~ ^[0-9]+$ && "$CHECKPOINT_GB" =~ ^[0-9]+$ ]] || { echo "error: RAM_RESERVE_GIB and CHECKPOINT_GB are whole numbers" >&2; exit 2; }
# A reply's reasoning: GLM's template knows low, high and max (its default); at a few tokens a second
# max is hours, so a request that names no effort gets high, and its reasoning stops at THINKING_BUDGET
# tokens (~30 min at 4-5 tok/s). A request's own reasoning_effort wins.
REASONING_EFFORT="${REASONING_EFFORT:-high}"
THINKING_BUDGET="${THINKING_BUDGET:-8192}"
[[ "$REASONING_EFFORT" =~ ^(none|low|high|max)$ ]] || { echo "error: REASONING_EFFORT is none, low, high or max: $REASONING_EFFORT" >&2; exit 2; }
# Engine settings for an experiment, passed to the container as they are (space-separated K=V).
NATIVE_EXTRA_ENV="${NATIVE_EXTRA_ENV:-}"
NAME="glm53-native"
PORT=8000
CONTAINER_HOME="$GLM_DIR/.home"
MODE="${1:---launch}"

case "$MODE" in
  --preflight | --install | --launch | --stop) ;;
  *) echo "usage: ${0##*/} [--preflight|--install|--launch|--stop]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

if [ "$MODE" = --stop ]; then
  inference_stop_container_if_present "$NAME"
  echo "stopped $NAME"
  exit 0
fi

# --- pins: image, sources, engine, files ----------------------------------------------------
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE is absent (ds4-native: scripts/dev.sh image)"
mountpoint -q "$STORE_DIR" || die "$STORE_DIR is not mounted (rpool/models/glm53-store)"
mountpoint -q /models/ds41 || die "/models/ds41 is not mounted (rpool/models/ds41: Maya's checkout and server)"
git -C "$MAYA_DIR" cat-file -e "$MAYA_COMMIT^{commit}" 2>/dev/null || die "Maya checkout at $MAYA_DIR has no commit $MAYA_COMMIT"
[ -f "$MAYA_DIR/.venv/pyvenv.cfg" ] || die "Maya's .venv is missing ($MAYA_DIR/.venv; its python is the image's)"
for f in "$STORE" "$CHECKPOINT/config.json" "$CHECKPOINT/tokenizer.json" "$CHECKPOINT/chat_template.jinja"; do
  [ -f "$f" ] || die "missing $f"
done
# The checkpoint revision the store and Backbone A were converted from (hf download's record of it).
[ "$(head -1 "$CHECKPOINT/.cache/huggingface/download/config.json.metadata" 2>/dev/null)" = "${CHECKPOINT_SOURCE#*@}" ] \
  || die "$CHECKPOINT is not ${CHECKPOINT_SOURCE}'s download"
# The Backbone's provenance: A is the checkpoint's (its 88 parts, no variant record); a variant names
# its source and that it was built on A (its base's directory: each build saw the store at its own mount).
[ "$(find "$BACKBONE" -maxdepth 1 -name 'backbone-*.safetensors' | wc -l)" = 88 ] || die "$BACKBONE does not hold the 88 Backbone parts"
case "$WEIGHTS" in
  uncensored) [ ! -e "$BACKBONE/VARIANT.json" ] || die "$BACKBONE carries a variant record: it is not Backbone A" ;;
  *)
    [ "$(jq -r '.source.repo + "@" + .source.revision' "$BACKBONE/VARIANT.json" 2>/dev/null)" = "$BACKBONE_SOURCE" ] \
      || die "$BACKBONE is not ${BACKBONE_SOURCE}'s variant (WEIGHTS=$WEIGHTS)"
    [ "$(jq -r '.base | split("/") | last' "$BACKBONE/VARIANT.json")" = backbone-uncensored ] || die "$BACKBONE was not built on Backbone A"
    ;;
esac

container_run=(--user "$(id -u):$(id -g)" -e HOME="$CONTAINER_HOME" -e PYTHONDONTWRITEBYTECODE=1
  -v /models/ds41:/models/ds41 -v "$GLM_DIR:$GLM_DIR" -v "$STORE_DIR:$STORE_DIR:ro")
mkdir -p "$CONTAINER_HOME" "$SERVE_DIR/bin"

if [ "$MODE" = --install ]; then
  git -C "$DS4N_SRC" fetch -q origin
  git -C "$DS4N_SRC" cat-file -e "$DS4N_COMMIT^{commit}" 2>/dev/null || die "$DS4N_SRC has no commit $DS4N_COMMIT"
  scratch="$(mktemp -d "$SERVE_DIR/.build-${DS4N_COMMIT:0:12}.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  git -C "$DS4N_SRC" archive "$DS4N_COMMIT" | tar -x -C "$scratch"
  docker run --rm "${container_run[@]}" -v "$scratch:/src" -w /src "$IMAGE" bash -c \
    "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc >/dev/null \
     && cmake --build build --target ds4n-glm53-serve ds4n_tests && build/ds4n_tests >/dev/null"
  # The tokenizer in Maya's form, from the checkpoint's tokenizer.json, checked id for id against
  # HF tokenizers (prose, code, numbers, scripts, specials, chats rendered by both templates).
  docker run --rm "${container_run[@]}" -v "$scratch:/src:ro" "$IMAGE" python3 -I /src/tools/glm53-serve/write_tokenizer.py \
    --checkpoint "$CHECKPOINT" --out "$TOKENIZER.tmp" --check "$MAYA_DIR"
  rm -rf "$TOKENIZER" && mv "$TOKENIZER.tmp" "$TOKENIZER"
  install -m 755 "$scratch/build/ds4n-glm53-serve" "$ENGINE"
  echo "$DS4N_COMMIT" >"$ENGINE.commit"
  # The server: the pinned commit's tree with the patch, its tests run (Maya's .venv; no GPU). The
  # DS4.1 launcher installs the same copy: whichever runs first builds it.
  if [ ! -f "$MAYA_SERVE/.installed" ]; then
    rm -rf "$MAYA_SERVE.tmp" && mkdir -p "$MAYA_SERVE.tmp"
    git -C "$MAYA_DIR" archive "$MAYA_COMMIT" | tar -x -C "$MAYA_SERVE.tmp"
    patch -d "$MAYA_SERVE.tmp" -p1 --batch --forward --quiet <"$MAYA_PATCH"
    docker run --rm "${container_run[@]}" -w "$MAYA_SERVE.tmp" "$IMAGE" "$MAYA_DIR/.venv/bin/python" -m unittest -q \
      serve.test_keepalive serve.test_server serve.test_tools serve.test_stop serve.test_fair
    echo "$MAYA_COMMIT $(sha256sum "$MAYA_PATCH" | cut -d' ' -f1)" >"$MAYA_SERVE.tmp/.installed"
    rm -rf "$MAYA_SERVE" && mv "$MAYA_SERVE.tmp" "$MAYA_SERVE"
  fi
  echo "installed $ENGINE, $TOKENIZER and $MAYA_SERVE"
  exit 0
fi

[ -x "$ENGINE" ] && [ "$(cat "$ENGINE.commit" 2>/dev/null)" = "$DS4N_COMMIT" ] || die "engine $ENGINE is not installed: ${0##*/} --install"
[ -f "$TOKENIZER/vocab.json" ] && [ -f "$TOKENIZER/chat_template.jinja" ] || die "tokenizer $TOKENIZER is missing: ${0##*/} --install"
[ -f "$MAYA_SERVE/.installed" ] || die "the patched server $MAYA_SERVE is not installed: ${0##*/} --install"

if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 ds4-native preflight: PASS (image $IMAGE, engine ${DS4N_COMMIT:0:12}, Maya ${MAYA_SERVE##*/}, $WEIGHTS Backbone, context $CONTEXT, λ $LAMBDA, eviction $EVICTION, VRAM reserve $RUNTIME_RESERVE_GIB GiB, $SLOT_SHAPE Slots, defer $DEFER)"
  exit 0
fi

# --- workstation gates ------------------------------------------------------------------------
if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  die "comfyui.service is active; stop it before reserving both GPUs"
fi
mapfile -t gpu_rows < <(nvidia-smi --query-gpu=index,name,memory.used --format=csv,noheader,nounits)
[ "${#gpu_rows[@]}" -eq 2 ] || die "this profile requires exactly two GPUs; found ${#gpu_rows[@]}"
for row in "${gpu_rows[@]}"; do
  IFS=, read -r index name memory_used <<<"$row"
  [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || die "GPU ${index// /} is not an RTX PRO 6000 Blackwell: $name"
  ((${memory_used// /} <= 1024)) || die "GPU ${index// /} has ${memory_used// /} MiB in use; stop every GPU workload"
done
inference_remove_container_if_present "$NAME"
others="$(docker ps --filter name='^glm53-' --format '{{.Names}}')"
[ -z "$others" ] || die "glm53-* containers are running ($others): the RAM tier must not share the host's memory with them"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  die "host port 8000 is already listening; stop the active profile first"
fi

# --- the server's config (rewritten each launch from the values above) ------------------------
jq -n --arg exe "$ENGINE" --arg config "$CHECKPOINT/config.json" --arg backbone "$BACKBONE" --arg store "$STORE" \
  --arg context "$CONTEXT" --arg lambda "$LAMBDA" --arg eviction "$EVICTION" --arg vram "$RUNTIME_RESERVE_GIB" \
  --arg profile "$SLOT_PROFILE" --arg reserve "$RAM_RESERVE_GIB" --arg ckpt "$CHECKPOINT_GB" --arg defer "$DEFER" \
  --arg cwd "$SERVE_DIR" --arg tok "$TOKENIZER" --arg model "$SERVED_MODEL" --arg log "$SERVE_DIR/glm53-native.log" \
  --arg effort "$REASONING_EFFORT" --argjson budget "$THINKING_BUDGET" --argjson port "$PORT" '{
    exe: $exe,
    args: ["--config", $config, "--backbone", $backbone, "--store", $store, "--max-context", $context,
           "--lambda", $lambda, "--eviction", $eviction, "--runtime-reserve-gib", $vram,
           "--ram-per-layer", "auto", "--ram-reserve-gib", $reserve, "--checkpoint-gb", $ckpt]
          + (if $profile == "" then [] else ["--slot-profile", $profile] end)
          + (if $defer == "off" then [] else ["--defer", $defer] end),
    cwd: $cwd, tokenizer: $tok, model_name: $model, gpu: [0, 1],
    # As the generation_config.json of the checkpoint.
    sampling: {temperature: 1.0, top_p: 0.95, repetition_penalty: 1.1},
    reasoning_effort: $effort, thinking_budget: $budget,
    port: $port, host: "0.0.0.0", log: $log
  }' >"$CONFIG.tmp"
mv -f "$CONFIG.tmp" "$CONFIG"

inference_prepare_api_key "${VLLM_API_KEY:-}"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/glm53-native/server.env"
inference_install_private_dir "$(dirname "$ENVFILE")"
inference_write_private_file "$ENVFILE" <<EOF
STRATA_API_KEY=$INFERENCE_API_KEY
EOF

extra_env=()
for kv in $NATIVE_EXTRA_ENV; do
  [[ "$kv" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]] || die "NATIVE_EXTRA_ENV entry is not K=V: $kv"
  extra_env+=(-e "$kv")
done

# io_uring (the Expert store reads) needs seccomp lifted: Docker's default profile blocks
# io_uring_setup/enter. memlock unlimited: the RAM tier is pinned. --fit-max-tokens: a request whose
# max_tokens does not fit the context beside its prompt gets the room there is instead of a 400.
docker run -d --name "$NAME" --restart no \
  --label ai.peterstorm.inference.profile="$NAME" \
  --label ai.peterstorm.inference.served-model="$SERVED_MODEL" \
  --label ai.peterstorm.inference.backbone="$BACKBONE_SOURCE" \
  --label ai.peterstorm.inference.ds4n-commit="$DS4N_COMMIT" \
  --label ai.peterstorm.inference.maya-commit="$MAYA_COMMIT" \
  --label ai.peterstorm.inference.maya-serve="${MAYA_SERVE##*/}" \
  --label ai.peterstorm.inference.context="$CONTEXT" \
  --label ai.peterstorm.inference.lambda="$LAMBDA" \
  --label ai.peterstorm.inference.eviction="$EVICTION" \
  --label ai.peterstorm.inference.runtime-reserve-gib="$RUNTIME_RESERVE_GIB" \
  --label ai.peterstorm.inference.slot-shape="$SLOT_SHAPE" \
  --label ai.peterstorm.inference.defer="$DEFER" \
  --label ai.peterstorm.inference.extra-env="$NATIVE_EXTRA_ENV" \
  --env-file "$ENVFILE" "${extra_env[@]}" \
  --gpus all --ipc host --network host --ulimit memlock=-1 --security-opt seccomp=unconfined \
  "${container_run[@]}" -w "$MAYA_SERVE" --entrypoint bash "$IMAGE" -c \
  "exec '$MAYA_DIR/.venv/bin/python' serve/server.py --engine strata --config '$CONFIG' --host 0.0.0.0 --port '$PORT' --fit-max-tokens" >/dev/null
echo "launched $NAME (model $SERVED_MODEL on :$PORT; loading takes ~2 minutes); logs: docker logs -f $NAME, $SERVE_DIR/glm53-native.log"

# --- back at boot once it has served -------------------------------------------------------------
# Launched restart=no and promoted to unless-stopped only once /v1/models lists $SERVED_MODEL: the
# profile last launched and healthy comes back with Docker at boot, a stopped one stays down, and an
# engine that never came up cannot crash-loop the next boot.
deadline=$((SECONDS + ${STARTUP_TIMEOUT_SECONDS:-1200}))
until curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $INFERENCE_API_KEY" \
  "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | jq -e --arg m "$SERVED_MODEL" 'any(.data[]; .id == $m)' >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || die "$NAME exited while loading (restart=no): docker logs $NAME"
  ((SECONDS < deadline)) || die "$NAME did not serve $SERVED_MODEL within ${STARTUP_TIMEOUT_SECONDS:-1200}s (restart=no)"
  sleep 5
done
docker update --restart=unless-stopped "$NAME" >/dev/null || die "could not set $NAME to restart=unless-stopped"
echo "serving $SERVED_MODEL; $NAME comes back with Docker at boot (restart=unless-stopped) until stopped"
