#!/usr/bin/env bash
# Contract for the DS4.1-1017 native launcher's Engram copy (ENGRAM, --write-engram).
#
# This runs the real launcher's --preflight and --write-engram against a model directory made in a
# temp dir. Stubs stand in for docker, git and mountpoint, and the docker stub logs the container
# runs the launcher would start. No image, GPU or desktop is needed. The test proves:
#   - ENGRAM is refused unless it names a copy of its own: relative, a colon, missing, a directory,
#     the GGUF, or the Expert store;
#   - the pinned engine and the copy tool must know the Engram copy;
#   - preflight runs the tool's --check, seccomp lifted, reaching the copy one way only;
#   - --write-engram refuses without ENGRAM and under a server reading it, and writes a new file;
#   - the launch passes --engram and labels the container.
#
# Block devices are opt-in, since they need a device the test may inspect (it never writes one;
# docker is a stub):
#   DS41_TEST_BLANK_DEVICE  a device with no file system (e.g. a loop device over a fresh file):
#                           accepted, given as --device with its group;
#   DS41_TEST_FS_DEVICE     a device holding a file system: refused.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN="$ROOT/scripts/inference/deepseek/ds41-1017-native/run-ds41-1017-native.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
bash -n "$RUN"

# --- static: the launch takes the copy as it was checked -------------------------------------------
contains() { grep -Fq -- "$1" "$RUN" || fail "the launcher is missing: $1"; }
contains '+ (if $engram == "" then [] else ["--engram", $engram] end)),'
contains '--label ai.peterstorm.inference.engram="$engram"'
contains '"${container_run[@]}" "${replica_mounts[@]}" "${engram_read[@]}" -w "$MAYA_SERVE"'
contains "grep -aqF -- '[--engram PATH]' \"\$ENGINE\""
contains 'targets="ds4n-serve ds4n_tests${engram:+ ds4n-engram-copy}"'

# --- a model directory and stubs -------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
models="$tmp/models" native="$tmp/models/native" stubs="$tmp/stubs" log="$tmp/docker.log"
commit=0123456789abcdef0123456789abcdef01234567
maya_commit="$(sed -n 's/^MAYA_COMMIT="\([0-9a-f]\{40\}\)"$/\1/p' "$RUN")"
[ -n "$maya_commit" ] || fail "MAYA_COMMIT is not a full commit"
patch_sha="$(sha256sum "$(dirname "$RUN")/maya-serve-keepalive.patch" | cut -c1-12)"
mkdir -p "$stubs" "$models/project-maya/.venv" "$native/bin" "$native/serve/tokenizer" "$models/engram" \
  "$models/baseline" "$models/hf-1017-mtp" "$native/maya-${maya_commit:0:12}-$patch_sha" "$tmp/other"
touch "$models/project-maya/.venv/pyvenv.cfg" "$native/experts.ds4n" "$models/engram/DeepSeek-V4.1-Flash-1017-MXFP4.gguf" \
  "$models/baseline/maya-expert-profile.bin" "$models/hf-1017-mtp/tokenizer.json" \
  "$models/hf-1017-mtp"/model-0004{4,5,6}-of-00048.safetensors "$native/serve/tokenizer/vocab.json" \
  "$native/serve/tokenizer/chat_template.jinja" "$native/maya-${maya_commit:0:12}-$patch_sha/.installed"
# The deepseek Backbone: a safetensors header naming its source.
source_line="$(sed -n '/^  deepseek)$/,/;;/s/^    BACKBONE_SOURCE="\(.*\)"$/\1/p' "$RUN")"
json="{\"__metadata__\":{\"source\":\"$source_line\"}}"
{ printf '%b' "\\x$(printf %02x "${#json}")\\0\\0\\0\\0\\0\\0\\0"; printf %s "$json"; } >"$native/backbone.safetensors"
engine="$native/bin/ds4n-serve-${commit:0:12}" tool="$native/bin/ds4n-engram-copy-${commit:0:12}"
engine_knows() { printf 'usage: ds4n-serve %s\n' "$1" >"$engine"; chmod +x "$engine"; echo "$commit" >"$engine.commit"; }
engine_knows '--replica-depth N [--engram PATH]'
printf '#!/bin/sh\n' >"$tool" && chmod +x "$tool"
gguf="$models/engram/DeepSeek-V4.1-Flash-1017-MXFP4.gguf"

cat >"$stubs/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  image) exit 0 ;;
  inspect) [ -n "${STUB_SERVING:-}" ] && { echo "$STUB_SERVING"; exit 0; }; exit 1 ;;
  run) printf '%s\n' "$*" >>"$STUB_LOG"
       for a in "$@"; do [ "$a" = --check ] && exit "${STUB_CHECK_STATUS:-0}"; done; exit 0 ;;
  *) exit 0 ;;
esac
EOF
printf '#!/bin/sh\nexit 0\n' >"$stubs/git"
printf '#!/bin/sh\nexit 0\n' >"$stubs/mountpoint"
chmod +x "$stubs"/*

# run ENV... -- ARGS: the launcher's output in $out, its status in $status, the docker runs in $runs.
run() {
  local env=()
  while [ "$1" != -- ]; do env+=("$1"); shift; done
  shift
  : >"$log"
  status=0
  out="$(env PATH="$stubs:$PATH" STUB_LOG="$log" MODELS_DIR="$models" DS4N_COMMIT="$commit" WEIGHTS=deepseek \
    "${env[@]}" bash "$RUN" "$@" 2>&1)" || status=$?
  runs="$(cat "$log")"
}
passes() { run "$@"; [ "$status" = 0 ] || fail "expected success for $*: ($status) $out"; }
dies() { # PATTERN ENV... -- ARGS: exit 1 or 2 with the message
  local want="$1"; shift
  run "$@"
  [ "$status" != 0 ] || fail "expected a refusal for $*: $out"
  [[ "$out" == *"$want"* ]] || fail "expected \"$want\" for $*: $out"
  [[ "$runs" != *--out* ]] || fail "a refusal still wrote a copy for $*"
}

# --- without ENGRAM: rows from the GGUF, no container run ------------------------------------------
passes -- --preflight
[[ "$out" == *"Engram rows from the GGUF"* ]] || fail "preflight without ENGRAM: $out"
[ -z "$runs" ] || fail "preflight without ENGRAM ran a container: $runs"

# --- a file copy -------------------------------------------------------------------------------------
copy="$native/engram.copy"
touch "$copy"
passes ENGRAM="$copy" -- --preflight
[[ "$out" == *"Engram rows $copy"* ]] || fail "preflight with a copy: $out"
[[ "$runs" == *"--security-opt seccomp=unconfined"*"$tool --check $copy $gguf"* ]] || fail "preflight's check: $runs"
[[ "$runs" != *" -v $native:"* ]] || fail "a copy MODELS_DIR holds is mounted again: $runs"
# Through a symlink: the resolved path is what is checked.
ln -s "$copy" "$tmp/other/link.copy"
passes ENGRAM="$tmp/other/link.copy" -- --preflight
[[ "$runs" == *"--check $copy "* ]] || fail "a symlinked ENGRAM is checked as its target: $runs"
# Outside MODELS_DIR: its directory, read-only, once.
outside="$tmp/other/engram.copy"
touch "$outside"
passes ENGRAM="$outside" -- --preflight
[[ "$runs" == *"-v $tmp/other:$tmp/other:ro "*"--check $outside "* ]] || fail "a copy outside MODELS_DIR: $runs"
# Beside a Store replica in the same directory: the replica's mount reaches it, and no second -v.
replica="$tmp/other/experts.ds4n"
touch "$replica"
passes STORE_REPLICAS="$replica" ENGRAM="$outside" -- --preflight
[ "$(grep -o -- "-v $tmp/other:" <<<"$runs" | wc -l)" = 1 ] || fail "the replica's directory mounted twice: $runs"
rm "$replica"

# --- refusals ----------------------------------------------------------------------------------------
dies "ENGRAM is an absolute path" ENGRAM=relative/engram.copy -- --preflight
dies "ENGRAM is an absolute path" ENGRAM="$tmp/a:b" -- --preflight
dies "missing $tmp/none" ENGRAM="$tmp/none" -- --preflight
dies "neither a partition nor a file" ENGRAM="$tmp/other" -- --preflight
dies "the GGUF itself" ENGRAM="$gguf" -- --preflight
ln -s "$gguf" "$tmp/other/gguf-link"
dies "the GGUF itself" ENGRAM="$tmp/other/gguf-link" -- --preflight
ln "$native/experts.ds4n" "$native/store-link"
dies "is the file $native/experts.ds4n is" ENGRAM="$native/store-link" -- --preflight
dies "does not check against" STUB_CHECK_STATUS=1 ENGRAM="$copy" -- --preflight
rm "$tool"
dies "is not installed" ENGRAM="$copy" -- --preflight
printf '#!/bin/sh\n' >"$tool" && chmod +x "$tool"
engine_knows '--replica-depth N'
dies "predates the Engram copy" ENGRAM="$copy" -- --preflight
engine_knows '--replica-depth N [--engram PATH]'

# --- --write-engram ----------------------------------------------------------------------------------
dies "--write-engram needs ENGRAM" -- --write-engram
dies "no directory $tmp/nowhere" ENGRAM="$tmp/nowhere/engram.copy" -- --write-engram
dies "is serving from $copy" STUB_SERVING="true $copy" ENGRAM="$copy" -- --write-engram
passes STUB_SERVING="true /dev/other" ENGRAM="$copy" -- --write-engram
[[ "$runs" == *"--security-opt seccomp=unconfined"*"$tool --out $copy $gguf"* ]] || fail "--write-engram's run: $runs"
# A new file outside MODELS_DIR: its directory read-write.
passes ENGRAM="$tmp/other/new.copy" -- --write-engram
[[ "$runs" == *"-v $tmp/other:$tmp/other "*"--out $tmp/other/new.copy "* ]] || fail "--write-engram to a new file: $runs"
[ ! -e "$tmp/other/new.copy" ] || fail "the launcher itself made the file (the tool writes it)"

# --- partitions (opt-in) -----------------------------------------------------------------------------
if [ -n "${DS41_TEST_BLANK_DEVICE:-}" ]; then
  dev="$(realpath -e "$DS41_TEST_BLANK_DEVICE")"
  gid="$(stat -c %g "$dev")"
  passes ENGRAM="$DS41_TEST_BLANK_DEVICE" -- --preflight
  [[ "$runs" == *"--device $dev:$dev:r --group-add $gid "*"--check $dev "* ]] || fail "a partition's check: $runs"
  passes ENGRAM="$DS41_TEST_BLANK_DEVICE" -- --write-engram
  [[ "$runs" == *"--device $dev:$dev:rw --group-add $gid "*"--out $dev "* ]] || fail "a partition's write: $runs"
  echo "  partition: $dev accepted"
fi
if [ -n "${DS41_TEST_FS_DEVICE:-}" ]; then
  dies "holds a file system" ENGRAM="$DS41_TEST_FS_DEVICE" -- --write-engram
  echo "  partition with a file system: refused"
fi

echo "ds41-1017-native Engram copy contract: PASS"
