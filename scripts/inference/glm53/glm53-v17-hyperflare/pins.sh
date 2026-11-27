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
# for GLM-5.3 Flash. Both PRs were open, not merged, when pinned (2026-11-27);
# these are their head commits then, so a later force-push cannot change what
# this profile builds.

# NVIDIA/hyperflare-inference: ignition (preparation), heliopause and the
# native flare server, all three from this one commit. NOT the commit the
# recipes' uv.lock names: that lock (PR #55's and main's alike) still resolves
# ignition to 425ab2d4 (2026-11-23), which has no ignition.parameters, and every
# recipe imports it since recipes #54 (2026-11-26). This is upstream main when
# PR #55's last commit landed (2026-11-27 06:27Z): it carries #545 (the
# RecipeParameters CLI the recipes import) and #508 (recipe-declared row-sharded
# attention planning PR #55 builds on). The Dockerfile re-locks onto it.
V17_HYPERFLARE_INFERENCE_COMMIT="6d74db3a0f5c04ebcd1adf10b5b112f7cc70a7cb"
# What the recipes' stale lock pins, kept so the contract can show the override.
V17_RECIPES_LOCKED_HYPERFLARE_INFERENCE_COMMIT="425ab2d4696caee841b1fc8165ff8d806a5af7e9"
# local-inference-lab/hyperflare-recipes PR #55 head: "sequence-parallel
# row-sharded prefill for GLM-5.3-Flash" (--row-shard-prefill,
# --row-shard-attention, on-the-fly attention weight gather).
V17_RECIPES_COMMIT="3009ec527d2b74a6691461124abdac298093ff01"
# local-inference-lab/flashinfer PR #151 head: the b12x kernels PR #55 needs
# (KDA segment summarize/finalize, GLM ARBITRARY_FP32 prefill MLA fusion, the
# cooperative MoE SM reservation, high-priority PCIe DMA streams). It sits on
# main 8bdfd6c9, the commit PR #55's own uv.lock pins.
V17_FLASHINFER_COMMIT="82f23e5ed78645df74869901837f213e7c1fc367"

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
#   rowshard  PR #55: --row-shard-prefill --row-shard-attention with 8192-token
#             chunks (the PR's threshold: chunks of 8192+ run row-sharded attention
#             with on-the-fly weight gather; smaller ones stay head-sharded)
#   baseline  upstream's default: head-sharded prefill, 4096-token chunks
V17_PREFILL_MODES=(rowshard baseline)

# v17_prefill_chunk MODE: the prefill chunk size the mode exports with; status 1
# for an unknown mode. Pure.
v17_prefill_chunk() {
  case "$1" in
    rowshard) echo 8192 ;;
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
