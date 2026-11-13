#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on ds4-native (peterstorm/ds4-native): the released MXFP4 Experts
# streamed from the NVMe into a VRAM Expert cache on the two RTX PRO 6000s, Exact against the
# engine's Reference configuration, behind Project Maya's OpenAI-compatible server.
#
# Maya's server (serve/server.py, MIT, at the pinned commit of the Maya checkout) renders the chat
# with DeepSeek-V4.1's own encoding, tokenizes, parses tool calls and streams; it starts
# `ds4n-serve --serve ARGS` and speaks Maya's engine protocol with it over stdin/stdout (GEN / T /
# DONE). Served on :8000 like every other profile, with the shared inference key, as
# warmind-1017-native (262,144-token context, the executor's): jcartu's abliterated WARMIND-1017,
# which differs from DeepSeek's release only in its Backbone; WEIGHTS=deepseek serves the release
# as deepseek-v4.1-flash-native. Once a launch serves, the container restarts with Docker at boot
# until it is stopped.
#
# What the repository owns:
#   - the Backbone by source (WEIGHTS): each names the HF repo and revision it was fetched from in
#     its header (ds4-native tools/hf-backbone), and the launch refuses one that names another;
#   - the image by name (ds4-native-dev:2, ds4-native's dev image: CUDA 13.4 + Python 3.12, the
#     base Maya's .venv was made in);
#   - the engine by commit (DS4N_COMMIT): --install builds ds4n-serve from that commit of the
#     desktop's clone into /models/ds41/native/bin/ds4n-serve-<commit>, which --launch runs;
#   - the Maya server by commit (MAYA_COMMIT, in the shared checkout's history), and the tokenizer exported
#     from the HF checkpoint by Maya's tools/ds4/pack.py (write_tokenizer). The server runs from a
#     copy of that commit with maya-serve-keepalive.patch applied (--install builds it, keyed by the
#     commit and the patch): keep-alives while tokens flow with nothing to send, so a tool call whose
#     parameter is held back until complete (a large file write) outlasts a client's read timeout,
#     and while a request waits in line behind other requests' answers (several agents at once:
#     Node's fetch cuts a request after 300 s without a byte);
#   - the engine's settings: Slots, RAM tier, the Expert profile, DSpark, the sweep threshold;
#   - the workstation gates: two idle RTX PRO 6000s, comfyui stopped, port 8000 free.
#
# Requests from any conversation it keeps: an agent's tool loop and a chat's next turn read only
# their new tokens; a conversation another one took its place on the GPUs from comes back from its KV
# checkpoint in host RAM (CHECKPOINT_GB of them), with the rings at its last prompt's end, so its
# next step resumes there however it re-renders the reply; a subagent's first prompt resumes where it leaves
# the system prompt it shares with its parent (a Rewind point taken there). LANES of them run at once
# (pi's parallel subagents, Loom's Wave gates and panels), their rows sharing the engine's Rounds, each
# Reply the bits it is alone; requests beyond that take turns in the server's line, each kept alive
# while it waits (ds4-native serving.md, Concurrent Sessions).
#
# Modes:
#   --preflight   check every pin without touching the GPUs
#   --install     build the pinned engine (once per DS4N_COMMIT; GPUs not needed)
#   --launch      start the server container (default); returns once it serves, set to restart at boot
#   --stop        stop it (and so keep it down at boot)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../../shared/inference-profile-catalog.sh"

IMAGE="ds4-native-dev:2"
DS4N_COMMIT="${DS4N_COMMIT:-c9a920068bed7248bd76c20035b4fd4ec7d19ff7}"
DS4N_SRC="${DS4N_SRC:-$HOME/dev/ds4-native}"
MAYA_COMMIT="b3fa99ec244e7885ec04ef456eac0d52474dba95"
MODELS_DIR="${MODELS_DIR:-/models/ds41}"
MAYA_DIR="$MODELS_DIR/project-maya"
MAYA_PATCH="$SCRIPT_DIR/maya-serve-keepalive.patch"
NATIVE="$MODELS_DIR/native"
MAYA_SERVE="$NATIVE/maya-${MAYA_COMMIT:0:12}-$(sha256sum "$MAYA_PATCH" | cut -c1-12)"
SERVE_DIR="$NATIVE/serve"
ENGINE="$NATIVE/bin/ds4n-serve-${DS4N_COMMIT:0:12}"
TOKENIZER="$SERVE_DIR/tokenizer"
CONFIG="$SERVE_DIR/ds4-native.json"
# Whose dense weights the Backbone carries. The routed Experts, the Engram tables and the DSpark head
# are DeepSeek's bytes in both, so the store, the GGUF and the profile serve either:
#   deepseek  DeepSeek's released Backbone;
#   warmind   WARMIND-1017 (jcartu; norm-preserving biprojected abliteration, alpha 3): 132 tensors
#             re-written -- attn.wo_b and ffn.shared_experts.w2, weights and scales, layers 4-36 --
#             and every other byte DeepSeek's (its DERIVATIVE.json). Fetched like DeepSeek's, by
#             /models/ds41/native/warmind/fetch_backbone.sh. The default.
# Maya answers any model name with what is loaded; the served name is what /v1/models reports.
WEIGHTS="${WEIGHTS:-warmind}"
case "$WEIGHTS" in
  deepseek)
    BACKBONE="$NATIVE/backbone.safetensors"
    BACKBONE_SOURCE="deepseek-ai/DeepSeek-V4.1-Flash-1017@1bae0e1088993b9b82de08f59de5be5a34e42170"
    SERVED_MODEL="deepseek-v4.1-flash-native"
    ;;
  warmind)
    BACKBONE="$NATIVE/warmind/backbone.safetensors"
    BACKBONE_SOURCE="jcartu/WARMIND-1017@4fbce6300b1e579f608b28ad3325c88008ea4bd4"
    SERVED_MODEL="warmind-1017-native"
    ;;
  *) echo "error: WEIGHTS is deepseek or warmind: $WEIGHTS" >&2; exit 2 ;;
esac
STORE="$NATIVE/experts.ds4n"
GGUF="$MODELS_DIR/engram/DeepSeek-V4.1-Flash-1017-MXFP4.gguf"
HF="$MODELS_DIR/hf-1017-mtp"
# The DSpark head (its three mtp.* shards): DeepSeek's released one in $HF, or another in the same
# layout. Drafts are verified, so the head changes speed only, never the output.
DSPARK="${DSPARK:-$HF}"
PROFILE="$MODELS_DIR/baseline/maya-expert-profile.bin"
# Requests at once (Lanes: each a live conversation's caches on the GPUs, ~730 MiB a GPU, so 78 fewer
# Slots). Served 2026-11-13 against one Lane, with the settings below: five reviewers of one diff
# 91 -> 115 tok/s in all, the first four writing within ~13 s instead of one after another; four
# different agents the same tok/s, all writing within 8 s; a lone request 87 -> 78 tok/s (the Slots
# the Lanes take). LANES=1: taking turns, as before 2026-11-13; LANES=2 costs a lone request ~5 %.
LANES="${LANES:-4}"
[[ "$LANES" =~ ^[1-8]$ ]] || { echo "error: LANES is 1 to 8: $LANES" >&2; exit 2; }
# The Slots prompt sweeps load into, VRAM beside SLOTS: a layer's sweep reads at most its 384 Experts,
# so 384 serves prompts as fast as the engine's default 512 and leaves 128 more for SLOTS.
SWEEP_SLOTS="${SWEEP_SLOTS:-384}"
# VRAM Slots and RAM tier records. Without DSpark the long-prompt setting is 8,800 Slots (95.6 GB
# VRAM beside a 64K prompt sweep); DSpark's stages, its 384 resident Experts and feature rings take
# ~300 Slots of that (8,800 runs out of memory at load), and the 256K context's caches another ~25
# (8,500 ran out instantiating the decode graphs): 8,400 beside 512 sweep Slots, so 8,528 beside 384,
# less 78 a Lane after the first (8,450 at 2 and 8,294 at 4 measured to fit). Every Expert that is in
# neither is read from the NVMe (1.7 ms against 0.36 from a record), a fifth of the Loads and over half
# of the wait for them: 3,400 records serve ~7 % more tok/s than 3,000 on every arm, for 7 GiB more
# pinned (61 GiB); with the server loaded ~8 GiB then stay free, and ZFS's ARC gives way past that.
# RAM_RECORDS=3000 is the setting before 2026-11-13.
SLOTS="${SLOTS:-$((8528 - 78 * (LANES - 1)))}"
RAM_RECORDS="${RAM_RECORDS:-3400}"
# How the RAM tier chooses its records: victim (exclusive: the Experts the VRAM Slots evicted, copied down
# as they go, so the two hold distinct Experts; 48 of the Slots are spares), popular (decayed load count,
# warmed with the profile's next-hottest Experts after the VRAM set) or recent (the last loaded). Victim
# against popular, served 2026-11-04: prefill +26-48 %, a warm code reply 77 -> 135 tok/s, the reply after
# a fresh prompt 60 -> 84 (engine::RamPolicy; ds4-native docs/design/forward-pass.md).
RAM_POLICY="${RAM_POLICY:-victim}"
[[ "$RAM_POLICY" =~ ^(popular|recent|victim)$ ]] || { echo "error: RAM_POLICY is popular, recent or victim: $RAM_POLICY" >&2; exit 2; }
# A prompt's unread tail goes as a prompt sweep from this many tokens, else as Rounds of 8: a sweep
# costs ~0.9 s plus ~0.6 ms a token, Rounds ~11 ms a token at 9K context (ds4n-serve-check --timing).
SWEEP_MIN="${SWEEP_MIN:-96}"
# Conversations set aside whole in host RAM (KV checkpoints: ~5.5 KB a token and 92 MB of rings, both
# GPUs' -- a 20K-token agent ~200 MB, a 250K-token one ~1.5 GB): the least recently used go first
# past this. With the server loaded ~8 GiB stay free of 91; 6 GB of checkpoints and 8 Rewind points
# (92 MB pinned each) take most of that (the ARC's 16 GB shrink under pressure). The engine wants
# more Rewind points than Lanes.
CHECKPOINT_GB="${CHECKPOINT_GB:-6}"
REWIND_POINTS="${REWIND_POINTS:-8}"
# Engine settings for an experiment, passed to the container as they are (space-separated K=V, e.g.
# NATIVE_EXTRA_ENV="DS4N_DECODER_TAIL=0" for every layer on every prompt row); empty for the profile.
NATIVE_EXTRA_ENV="${NATIVE_EXTRA_ENV:-}"
NAME="ds41-1017-native"
PORT=8000
CONTAINER_HOME="$MODELS_DIR/.home"
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
mountpoint -q "$MODELS_DIR" || die "$MODELS_DIR is not mounted (rpool/models/ds41)"
# The server runs from its own copy of MAYA_COMMIT (MAYA_SERVE), so the checkout itself may sit
# wherever the Maya profile pins it; the commit only has to be in its history.
git -C "$MAYA_DIR" cat-file -e "$MAYA_COMMIT^{commit}" 2>/dev/null || die "Maya checkout at $MAYA_DIR has no commit $MAYA_COMMIT"
[ -f "$MAYA_DIR/.venv/pyvenv.cfg" ] || die "Maya's .venv is missing ($MAYA_DIR/.venv; its python is the image's)"
for f in "$BACKBONE" "$STORE" "$GGUF" "$PROFILE" "$HF/tokenizer.json" "$DSPARK"/model-0004{4,5,6}-of-00048.safetensors; do
  [ -f "$f" ] || die "missing $f"
done
# The source hf-backbone recorded in the Backbone's safetensors header (__metadata__.source).
backbone_source() {
  local header
  header="$(head -c 8 "$1" | od -An -tu8 | tr -d ' ')"
  dd if="$1" iflag=skip_bytes,count_bytes skip=8 count="$header" status=none | jq -r '.__metadata__.source // empty'
}
[ "$(backbone_source "$BACKBONE")" = "$BACKBONE_SOURCE" ] || die "$BACKBONE is not $BACKBONE_SOURCE's Backbone (WEIGHTS=$WEIGHTS)"

container_run=(--user "$(id -u):$(id -g)" -e HOME="$CONTAINER_HOME" -e PYTHONDONTWRITEBYTECODE=1 -v "$MODELS_DIR:$MODELS_DIR")
mkdir -p "$CONTAINER_HOME" "$NATIVE/bin" "$SERVE_DIR"

if [ "$MODE" = --install ]; then
  git -C "$DS4N_SRC" fetch -q origin
  git -C "$DS4N_SRC" cat-file -e "$DS4N_COMMIT^{commit}" 2>/dev/null || die "$DS4N_SRC has no commit $DS4N_COMMIT"
  scratch="$(mktemp -d "$NATIVE/.build-${DS4N_COMMIT:0:12}.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  git -C "$DS4N_SRC" archive "$DS4N_COMMIT" | tar -x -C "$scratch"
  docker run --rm "${container_run[@]}" -v "$scratch:/src" -w /src "$IMAGE" bash -c \
    "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc >/dev/null \
     && cmake --build build --target ds4n-serve ds4n_tests && build/ds4n_tests >/dev/null"
  install -m 755 "$scratch/build/ds4n-serve" "$ENGINE"
  echo "$DS4N_COMMIT" >"$ENGINE.commit"
  # The tokenizer in Maya's form, from the checkpoint's tokenizer.json (Maya's own exporter).
  docker run --rm "${container_run[@]}" -w "$MAYA_DIR/tools/ds4" "$IMAGE" "$MAYA_DIR/.venv/bin/python" -c \
    "import pathlib, pack; pack.write_tokenizer(pathlib.Path('$TOKENIZER'), pathlib.Path('$HF'))"
  # The server: the pinned commit's tree with the patch, its tests run (Maya's .venv; no GPU).
  if [ ! -f "$MAYA_SERVE/.installed" ]; then
    rm -rf "$MAYA_SERVE.tmp" && mkdir -p "$MAYA_SERVE.tmp"
    git -C "$MAYA_DIR" archive "$MAYA_COMMIT" | tar -x -C "$MAYA_SERVE.tmp"
    patch -d "$MAYA_SERVE.tmp" -p1 --batch --forward --quiet <"$MAYA_PATCH"
    docker run --rm "${container_run[@]}" -w "$MAYA_SERVE.tmp" "$IMAGE" "$MAYA_DIR/.venv/bin/python" -m unittest -q \
      serve.test_keepalive serve.test_server serve.test_tools serve.test_stop serve.test_ds41_conformance serve.test_fair
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
  echo "DS4.1-1017 ds4-native preflight: PASS (image $IMAGE, engine ${DS4N_COMMIT:0:12}, Maya ${MAYA_SERVE##*/}, $WEIGHTS Backbone, files present)"
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
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  die "host port 8000 is already listening; stop the active profile first"
fi

# --- the server's config (rewritten each launch from the values above) ------------------------
jq -n --arg exe "$ENGINE" --arg backbone "$BACKBONE" --arg store "$STORE" --arg gguf "$GGUF" --arg dspark "$DSPARK" \
  --arg profile "$PROFILE" --arg slots "$SLOTS" --arg ram "$RAM_RECORDS" --arg ram_policy "$RAM_POLICY" --arg sweep "$SWEEP_MIN" \
  --arg ckpt "$CHECKPOINT_GB" --arg points "$REWIND_POINTS" --arg lanes "$LANES" --arg sweep_slots "$SWEEP_SLOTS" \
  --arg cwd "$SERVE_DIR" --arg tok "$TOKENIZER" --arg model "$SERVED_MODEL" --arg log "$SERVE_DIR/ds4-native.log" \
  --argjson port "$PORT" '{
    exe: $exe,
    args: ["--backbone", $backbone, "--store", $store, "--gguf", $gguf, "--dspark", $dspark, "--slots", $slots,
           "--ram-records", $ram, "--prior", $profile, "--ram-policy", $ram_policy, "--sweep-min", $sweep,
           "--checkpoint-gb", $ckpt, "--rewind-points", $points, "--lanes", $lanes, "--sweep-slots", $sweep_slots],
    cwd: $cwd, tokenizer: $tok, model_name: $model, gpu: [0, 1],
    sampling: {temperature: 1.0, top_p: 1.0}, reasoning_effort: "high",
    # No thinking cap of its own (Maya defaults to 32,768): reasoning is bounded by the room left for
    # the reply, less the quarter Maya keeps for the answer so a reply never ends with no answer.
    thinking_budget: 262144,
    port: $port, host: "0.0.0.0", log: $log
  }' >"$CONFIG.tmp"
mv -f "$CONFIG.tmp" "$CONFIG"

inference_prepare_api_key "${VLLM_API_KEY:-}"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/ds41-native/server.env"
inference_install_private_dir "$(dirname "$ENVFILE")"
inference_write_private_file "$ENVFILE" <<EOF
STRATA_API_KEY=$INFERENCE_API_KEY
EOF

extra_env=()
for kv in $NATIVE_EXTRA_ENV; do
  [[ "$kv" =~ ^[A-Z][A-Z0-9_]*=[^[:space:]]*$ ]] || die "NATIVE_EXTRA_ENV entry is not K=V: $kv"
  extra_env+=(-e "$kv")
done

# io_uring (the Expert store and Engram reads) needs seccomp lifted: Docker's default profile blocks
# io_uring_setup/enter. --fit-max-tokens: a request whose max_tokens does not fit the context beside
# its prompt gets the room there is instead of a 400 (pi sends its model's maxTokens, the whole
# 262,144: a reply -- its reasoning included -- is bounded by the context alone).
docker run -d --name "$NAME" --restart no \
  --label ai.peterstorm.inference.profile="$NAME" \
  --label ai.peterstorm.inference.served-model="$SERVED_MODEL" \
  --label ai.peterstorm.inference.backbone="$BACKBONE_SOURCE" \
  --label ai.peterstorm.inference.ds4n-commit="$DS4N_COMMIT" \
  --label ai.peterstorm.inference.maya-commit="$MAYA_COMMIT" \
  --label ai.peterstorm.inference.maya-serve="${MAYA_SERVE##*/}" \
  --label ai.peterstorm.inference.extra-env="$NATIVE_EXTRA_ENV" \
  --label ai.peterstorm.inference.dspark="$DSPARK" \
  --label ai.peterstorm.inference.ram-policy="$RAM_POLICY" \
  --label ai.peterstorm.inference.lanes="$LANES" \
  --env-file "$ENVFILE" "${extra_env[@]}" \
  --gpus all --ipc host --network host --ulimit memlock=-1 --security-opt seccomp=unconfined \
  "${container_run[@]}" -w "$MAYA_SERVE" --entrypoint bash "$IMAGE" -c \
  "exec '$MAYA_DIR/.venv/bin/python' serve/server.py --engine strata --config '$CONFIG' --host 0.0.0.0 --port '$PORT' --fit-max-tokens" >/dev/null
echo "launched $NAME (model $SERVED_MODEL on :$PORT; loading takes a few minutes); logs: docker logs -f $NAME, $SERVE_DIR/ds4-native.log"

# --- back at boot once it has served -------------------------------------------------------------
# Launched restart=no and promoted to unless-stopped only once /v1/models lists $SERVED_MODEL: the
# profile last launched and healthy comes back with Docker at boot (as GLM's did), a stopped one
# (--stop, or another profile's launch) stays down, and an engine that never came up cannot
# crash-loop the next boot (a Maya build once wedged the box that way).
deadline=$((SECONDS + ${STARTUP_TIMEOUT_SECONDS:-1800}))
until curl -fsS --connect-timeout 2 --max-time 5 -H "Authorization: Bearer $INFERENCE_API_KEY" \
  "http://127.0.0.1:$PORT/v1/models" 2>/dev/null | jq -e --arg m "$SERVED_MODEL" 'any(.data[]; .id == $m)' >/dev/null 2>&1; do
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || die "$NAME exited while loading (restart=no): docker logs $NAME"
  ((SECONDS < deadline)) || die "$NAME did not serve $SERVED_MODEL within ${STARTUP_TIMEOUT_SECONDS:-1800}s (restart=no)"
  sleep 5
done
docker update --restart=unless-stopped "$NAME" >/dev/null || die "could not set $NAME to restart=unless-stopped"
echo "serving $SERVED_MODEL; $NAME comes back with Docker at boot (restart=unless-stopped) until stopped"
