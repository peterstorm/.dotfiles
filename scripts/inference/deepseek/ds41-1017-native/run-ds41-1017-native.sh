#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on ds4-native (peterstorm/ds4-native): the released MXFP4 Experts
# streamed from the NVMe into a VRAM Expert cache on the two RTX PRO 6000s, Exact against the
# engine's Reference configuration, behind Project Maya's OpenAI-compatible server.
#
# Maya's server (serve/server.py, MIT, at the pinned commit of the Maya checkout) renders the chat
# with DeepSeek-V4.1's own encoding, tokenizes, parses tool calls and streams; it starts
# `ds4n-serve --serve ARGS` and speaks Maya's engine protocol with it over stdin/stdout (GEN / T /
# DONE). Served on :8000 like every other profile, with the shared inference key, as
# deepseek-v4.1-flash-native (262,144-token context, the executor's).
#
# What the repository owns:
#   - the image by name (ds4-native-dev:2, ds4-native's dev image: CUDA 13.4 + Python 3.12, the
#     base Maya's .venv was made in);
#   - the engine by commit (DS4N_COMMIT): --install builds ds4n-serve from that commit of the
#     desktop's clone into /models/ds41/native/bin/ds4n-serve-<commit>, which --launch runs;
#   - the Maya server by commit (MAYA_COMMIT, in the shared checkout's history), and the tokenizer exported
#     from the HF checkpoint by Maya's tools/ds4/pack.py (write_tokenizer). The server runs from a
#     copy of that commit with maya-serve-keepalive.patch applied (--install builds it, keyed by the
#     commit and the patch): keep-alives while tokens flow with nothing to send, so a tool call whose
#     parameter is held back until complete (a large file write) outlasts a client's read timeout;
#   - the engine's settings: Slots, RAM tier, the Expert profile, DSpark, the sweep threshold;
#   - the workstation gates: two idle RTX PRO 6000s, comfyui stopped, port 8000 free.
#
# One request at a time, from any conversation it keeps: an agent's tool loop and a chat's next turn
# read only their new tokens; a conversation another one took the GPUs from comes back from its KV
# checkpoint in host RAM (CHECKPOINT_GB of them), with the rings at its last prompt's end, so its
# next step resumes there however it re-renders the reply; a subagent's first prompt resumes where it leaves
# the system prompt it shares with its parent (a Rewind point taken there).
#
# Modes:
#   --preflight   check every pin without touching the GPUs
#   --install     build the pinned engine (once per DS4N_COMMIT; GPUs not needed)
#   --launch      start the server container (default)
#   --stop        stop it
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../../shared/inference-profile-catalog.sh"

IMAGE="ds4-native-dev:2"
DS4N_COMMIT="${DS4N_COMMIT:-ea56a567eab667ce9413e79b2ab35f576b7c9cc6}"
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
BACKBONE="$NATIVE/backbone.safetensors"
STORE="$NATIVE/experts.ds4n"
GGUF="$MODELS_DIR/engram/DeepSeek-V4.1-Flash-1017-MXFP4.gguf"
HF="$MODELS_DIR/hf-1017-mtp"
PROFILE="$MODELS_DIR/baseline/maya-expert-profile.bin"
# VRAM Slots and RAM tier records. Without DSpark the long-prompt setting is 8,800 Slots (95.6 GB
# VRAM beside a 64K prompt sweep); DSpark's stages, its 384 resident Experts and feature rings take
# ~300 Slots of that (8,800 runs out of memory at load), and the 256K context's caches another ~25
# (8,500 ran out instantiating the decode graphs). 3,300 records are 62 GB pinned; 3,000 leave room
# for the server, the Rewind points and the checkpoints.
SLOTS="${SLOTS:-8400}"
RAM_RECORDS="${RAM_RECORDS:-3000}"
# A prompt's unread tail goes as a prompt sweep from this many tokens, else as Rounds of 8: a sweep
# costs ~0.9 s plus ~0.6 ms a token, Rounds ~11 ms a token at 9K context (ds4n-serve-check --timing).
SWEEP_MIN="${SWEEP_MIN:-96}"
# Conversations set aside whole in host RAM (KV checkpoints: ~5.5 KB a token and 92 MB of rings, both
# GPUs' -- a 20K-token agent ~200 MB, a 250K-token one ~1.5 GB): the least recently used go first
# past this. With the server loaded ~13 GB stay free of 91; 6 GB of checkpoints and 8 Rewind points
# (92 MB pinned each) leave ~6 GB.
CHECKPOINT_GB="${CHECKPOINT_GB:-6}"
REWIND_POINTS="${REWIND_POINTS:-8}"
# Engine settings for an experiment, passed to the container as they are (space-separated K=V, e.g.
# NATIVE_EXTRA_ENV="DS4N_DECODER_TAIL=0" for every layer on every prompt row); empty for the profile.
NATIVE_EXTRA_ENV="${NATIVE_EXTRA_ENV:-}"
NAME="ds41-1017-native"
SERVED_MODEL="deepseek-v4.1-flash-native"
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
for f in "$BACKBONE" "$STORE" "$GGUF" "$PROFILE" "$HF/tokenizer.json"; do [ -f "$f" ] || die "missing $f"; done

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
      serve.test_keepalive serve.test_server serve.test_tools serve.test_stop serve.test_ds41_conformance
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
  echo "DS4.1-1017 ds4-native preflight: PASS (image $IMAGE, engine ${DS4N_COMMIT:0:12}, Maya ${MAYA_SERVE##*/}, files present)"
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
jq -n --arg exe "$ENGINE" --arg backbone "$BACKBONE" --arg store "$STORE" --arg gguf "$GGUF" --arg hf "$HF" \
  --arg profile "$PROFILE" --arg slots "$SLOTS" --arg ram "$RAM_RECORDS" --arg sweep "$SWEEP_MIN" \
  --arg ckpt "$CHECKPOINT_GB" --arg points "$REWIND_POINTS" \
  --arg cwd "$SERVE_DIR" --arg tok "$TOKENIZER" --arg model "$SERVED_MODEL" --arg log "$SERVE_DIR/ds4-native.log" \
  --argjson port "$PORT" '{
    exe: $exe,
    args: ["--backbone", $backbone, "--store", $store, "--gguf", $gguf, "--dspark", $hf, "--slots", $slots,
           "--ram-records", $ram, "--prior", $profile, "--ram-policy", "popular", "--sweep-min", $sweep,
           "--checkpoint-gb", $ckpt, "--rewind-points", $points],
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
  --label ai.peterstorm.inference.ds4n-commit="$DS4N_COMMIT" \
  --label ai.peterstorm.inference.maya-commit="$MAYA_COMMIT" \
  --label ai.peterstorm.inference.maya-serve="${MAYA_SERVE##*/}" \
  --label ai.peterstorm.inference.extra-env="$NATIVE_EXTRA_ENV" \
  --env-file "$ENVFILE" "${extra_env[@]}" \
  --gpus all --ipc host --network host --ulimit memlock=-1 --security-opt seccomp=unconfined \
  "${container_run[@]}" -w "$MAYA_SERVE" --entrypoint bash "$IMAGE" -c \
  "exec '$MAYA_DIR/.venv/bin/python' serve/server.py --engine strata --config '$CONFIG' --host 0.0.0.0 --port '$PORT' --fit-max-tokens" >/dev/null
echo "launched $NAME (model $SERVED_MODEL on :$PORT; loading takes a few minutes); logs: docker logs -f $NAME, $SERVE_DIR/ds4-native.log"
