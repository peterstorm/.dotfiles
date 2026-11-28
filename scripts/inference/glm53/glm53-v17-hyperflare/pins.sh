# shellcheck shell=bash
# shellcheck disable=SC2034 # every value here is read by the scripts that source it
# The one place the GLM-5.3 v17 Hyperflare profile's sources and names are
# pinned. The build script passes the commits to the Dockerfile as required
# build arguments, the image records them as labels, and the export and run
# scripts refuse an image whose labels differ (v17_image_matches_pins). Source
# it; it defines values and pure functions only.
# tests/glm53-flash-hyperflare-tp2-v17-contract.sh pins the values and
# tests/glm53-v17-hyperflare-unit.sh the functions.
#
# v17 is upstream Hyperflare instead of the AzallazA fork v16 runs, plus the two
# open Local Inference Lab PRs that add sequence-parallel row-sharded prefill
# for GLM-5.3 Flash. Both PRs were open, not merged, when pinned; these are
# their head commits then, so a later force-push cannot change what this
# profile builds. Re-pinned 2026-11-28: both PRs were rebased onto main (so v17
# carries main's 11-27 GLM decode and prefill wins, recipes #46/#49 and
# flashinfer #146-#149), and #55's new head fixes a ZeRO-3 KDA template
# corruption the first pin (3009ec52) still had.

# NVIDIA/hyperflare-inference: ignition (preparation), heliopause and the
# native flare server, all three from this one commit: the one PR #55 was
# validated with ("paired with flashinfer#151 and hyperflare-inference@c9935887"),
# upstream main on 2026-11-28 06:23Z. It carries #555 (batch capacities 6/12/24),
# #556 (lock-free same-process TP DispatchRing) and #557 (PreparedAllToAll).
# NOT the commit the recipes' uv.lock names (below); the Dockerfile re-locks onto
# this one. History: the first pin's recipes lock named 425ab2d4, which had no
# ignition.parameters at all.
V17_HYPERFLARE_INFERENCE_COMMIT="c99358879813f22557ac619044af514fafacecc6"
# What PR #55's own lock pins (main 2026-11-27 20:43Z, four commits before the
# validated one), kept so the contract can show the override.
V17_RECIPES_LOCKED_HYPERFLARE_INFERENCE_COMMIT="5adb27f259d340231c384ed668bd68e2abc313c5"
# local-inference-lab/hyperflare-recipes PR #55 head: "GLM-5.3 TP2/TP4
# row-sharded prefill, ZeRO-3 weight gather & MXFP8 attention"
# (--row-shard-prefill, --row-shard-attention), rebased onto main d1376bb4.
V17_RECIPES_COMMIT="71c9830c5720e19bc6bb6b53c028810edc09fab0"
# local-inference-lab/flashinfer PR #151 head: the b12x kernels PR #55 needs
# (KDA segment summarize/finalize, GLM ARBITRARY_FP32 prefill MLA fusion, the
# cooperative MoE SM reservation, high-priority PCIe DMA streams), rebased onto
# main 5d2a7107, the commit PR #55's own lock pins.
V17_FLASHINFER_COMMIT="6d2f90c8670691c168d762cda294dcf2f4eb6dc6"

# The image tag names all three sources (short ids) and the CUDA toolkit.
V17_IMAGE="peterstorm/glm53-hyperflare-upstream:hfi${V17_HYPERFLARE_INFERENCE_COMMIT:0:8}-hfr${V17_RECIPES_COMMIT:0:8}-fi${V17_FLASHINFER_COMMIT:0:8}-cu131"

# The served identity. v17 exports the v16 checkpoint (nvidia/GLM-5.3-Flash-FP4-Local),
# so its model name is v16's checkpoint directory; its container, served id and
# state root (and so its core store) are its own.
V17_CONTAINER="glm53-flash-hyperflare-tp2-v17"
V17_SERVED_MODEL="glm-5.3-flash-hyperflare-tp2-v17"
V17_MODEL="glm53-fp4-local"
V17_CHECKPOINT="nvidia/GLM-5.3-Flash-FP4-Local@76348ddb2be2e35e39ecfc00e75dc07703f4f3d5"
# The default state root (flare-home/, core receipts, logs). Export and run take it
# from here, so they cannot disagree about where cores live; V17_ROOT overrides it.
V17_DEFAULT_ROOT="/models/glm53-hyperflare-v17"

# The local development signing key v16's export minted (sha256 of its ed25519
# public key). The v17 export seeds its own state root with a copy of that key,
# so v17 cores are signed by the key the operator accepted on 2026-11-14.
V17_SIGNING_KEY_FINGERPRINT="f2bca6f9fd072391b10fc6fbd7c2cafd2e0e518fde57e0b05f2d48a22ef1e052"

# Image label keys, in the order v17_image_labels_format prints them.
V17_LABEL_HFI="ai.peterstorm.inference.hyperflare-commit"
V17_LABEL_HFR="ai.peterstorm.inference.recipes-commit"
V17_LABEL_FI="ai.peterstorm.inference.flashinfer-commit"

# v17_image_labels_format: the docker inspect --format string that prints the
# three source labels on one line, space-separated.
v17_image_labels_format() {
  printf '{{index .Config.Labels "%s"}} {{index .Config.Labels "%s"}} {{index .Config.Labels "%s"}}' \
    "$V17_LABEL_HFI" "$V17_LABEL_HFR" "$V17_LABEL_FI"
}

# v17_image_matches_pins "HFI HFR FI": status 0 when an image's three labels are
# exactly the pins; otherwise status 1 and the first mismatch on stdout. Pure.
v17_image_matches_pins() {
  local hfi hfr flashinfer extra
  read -r hfi hfr flashinfer extra <<<"$1"
  if [ -n "$extra" ]; then echo "unexpected label text '$extra'"; return 1; fi
  if [ "$hfi" != "$V17_HYPERFLARE_INFERENCE_COMMIT" ]; then
    echo "hyperflare-inference ${hfi:-<none>}, expected $V17_HYPERFLARE_INFERENCE_COMMIT"; return 1
  fi
  if [ "$hfr" != "$V17_RECIPES_COMMIT" ]; then
    echo "hyperflare-recipes ${hfr:-<none>}, expected $V17_RECIPES_COMMIT"; return 1
  fi
  if [ "$flashinfer" != "$V17_FLASHINFER_COMMIT" ]; then
    echo "flashinfer ${flashinfer:-<none>}, expected $V17_FLASHINFER_COMMIT"; return 1
  fi
}

# The two prefill modes a v17 core is exported in. Each is its own core and
# receipt, so the A/B is the same image, checkpoint and capacities with only the
# prefill path changed:
#   rowshard  PR #55: --row-shard-prefill --row-shard-attention with 12288-token
#             chunks. Over PCIe (this box) row-sharded attention engages only for
#             prefill graphs of 12288+ tokens (glm53/stack.py
#             ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE; 4096 and 8192 are RoCE's), and
#             12288 is the size the PR was validated at; smaller chunks would
#             silently keep head-sharded attention
#   baseline  upstream's default: head-sharded prefill, 4096-token chunks (what
#             would be served otherwise; the chunk size is part of the comparison)
V17_PREFILL_MODES=(rowshard baseline)

# The smallest prefill graph that runs row-sharded attention over PCIe (PR #55).
V17_ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE=12288

# v17_prefill_chunk MODE: the prefill chunk size the mode exports with; status 1
# for an unknown mode. Pure.
v17_prefill_chunk() {
  case "$1" in
    rowshard) echo "$V17_ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE" ;;
    baseline) echo 4096 ;;
    *) return 1 ;;
  esac
}

# v17_prefill_flags MODE: the ignition export flags the mode adds, one per line
# (none for baseline); status 1 for an unknown mode. Pure.
v17_prefill_flags() {
  case "$1" in
    rowshard) printf '%s\n' --row-shard-prefill --row-shard-attention ;;
    baseline) ;;
    *) return 1 ;;
  esac
}

# v17_resolve_prefill MODE: MODE itself for a known mode, else status 2 with the
# known modes on stderr (the form every launcher's top level wants).
v17_resolve_prefill() {
  v17_prefill_chunk "$1" >/dev/null 2>&1 || {
    echo "error: unknown PREFILL '$1' (known: ${V17_PREFILL_MODES[*]})" >&2
    return 2
  }
  echo "$1"
}

# v17_entry_from_export_log MODEL < LOG: the cache entry an ignition export
# published, from its last "Exported cache entry: <path>/MODEL/VERSION" line
# (ignition/cli/serve.py prints it); status 1 when the log has none for MODEL.
# VERSION is whatever the exporter chose: one path segment of [A-Za-z0-9._-]. Pure.
v17_entry_from_export_log() {
  local entry
  entry="$(sed -nE "s|^Exported cache entry: (/.*/$1/[A-Za-z0-9._-]+)/?\$|\\1|p" | tail -1)"
  [ -n "$entry" ] || return 1
  echo "$entry"
}

# v17_core_of_entry ENTRY: the "MODEL@VERSION" name flare run accepts for a
# cache entry path .../MODEL/VERSION. Pure.
v17_core_of_entry() {
  local version="${1##*/}" parent="${1%/*}"
  echo "${parent##*/}@$version"
}

# v17_receipt_core MODEL PREFILL < RECEIPT: the core a v17 export receipt names,
# parsed and checked once: status 1 with the reason on stdout unless the receipt
# names exactly one MODEL@VERSION core exported in PREFILL mode. Pure.
v17_receipt_core() {
  local receipt core prefill
  receipt="$(cat)"
  core="$(sed -n 's/^core=//p' <<<"$receipt")"
  prefill="$(sed -n 's/^prefill=//p' <<<"$receipt")"
  if [ "$(grep -c '^core=' <<<"$receipt")" != 1 ]; then echo "the receipt must name exactly one core"; return 1; fi
  if ! [[ "$core" =~ ^"$1"@[A-Za-z0-9._-]+$ ]]; then echo "the receipt names core '$core', expected $1@<version>"; return 1; fi
  if [ "$prefill" != "$2" ]; then echo "the receipt is for prefill '${prefill:-<none>}', expected $2"; return 1; fi
  echo "$core"
}
