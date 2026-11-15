# shellcheck shell=bash
# The Hyperflare GLM-5.3 TP2 variants, and what each one is. A variant is one
# checkpoint directory under /models/glm53-hyperflare, the package exported from
# it, the container that serves it and the id it is served as. The export, run
# and switch launchers all derive their names from the variant here, so a
# checkpoint, a package receipt and a container can never name different
# variants (MODEL is derived, never passed alongside VARIANT). Functions only:
# source it. tests/hyperflare-variants-unit.sh pins the table.
#
#   v16           nvidia/GLM-5.3-Flash-FP4-Local as downloaded.
#   uncensored    dealignai's GLM-5.3-Flash-UNCENSORED-NVFP4 (the refusal edit in
#                 every layer, experts included) converted by
#                 glm53-uncensored-convert.py into v16's storage, so it fits v16's
#                 GPU budget and KV room: every dense projection re-encoded into
#                 v16's FP8; the routed experts' FP4 codes and block scales exact,
#                 the scales slab-CSF encoded and the gate/up globals folded into
#                 down's (the draft layer's plain experts folded too, since b12x
#                 pairs unequal gate/up globals only in A4 mode); v16's expert
#                 input scales, chat template and vision tower.
#
# Retired 2026-11-15: cyber-hybrid and cyber-hybrid-bf16, the splices of
# dealignai's CYBERSECURITY build; the runbook keeps their sections as history.
#
# Adding a variant is one line in each case below; an unknown variant is a
# status, never a guess.

HYPERFLARE_VARIANTS=(v16 uncensored)

# hyperflare_variant_model VARIANT: the checkpoint directory, which Hyperflare
# also uses as the model name. Status 1 for a variant that does not exist.
hyperflare_variant_model() {
  case "$1" in
    v16) echo glm53-fp4-local ;;
    uncensored) echo glm53-uncensored ;;
    *) return 1 ;;
  esac
}

# hyperflare_variant_build_receipt VARIANT: the receipt a built checkpoint carries
# in its directory, written by the tool that built it; the export refuses a
# checkpoint without it. Status 1 for v16, which is downloaded, not built (its
# downloader's --verify is its gate), and for a variant that does not exist.
hyperflare_variant_build_receipt() {
  case "$1" in
    uncensored) echo convert-receipt.json ;;
    *) return 1 ;;
  esac
}

# The container and served id are derived, and only for a variant that exists.
hyperflare_variant_container() {
  hyperflare_variant_model "$1" >/dev/null && echo "glm53-flash-hyperflare-tp2-$1"
}
hyperflare_variant_served() {
  hyperflare_variant_model "$1" >/dev/null && echo "glm-5.3-flash-hyperflare-tp2-$1"
}

# hyperflare_variant_provenance VARIANT BASE: the container's checkpoint label.
# BASE is the pinned nvidia/GLM-5.3-Flash-FP4-Local@<revision> the run script
# carries; a tune names its donor build and revision next to it.
hyperflare_variant_provenance() {
  case "$1" in
    v16) echo "$2" ;;
    uncensored)
      echo "$2 (vision tower, expert input scales, storage formats) + dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4@745aac2ff0f10acf961f396df3f9418598aa7327 (every text weight; dense re-encoded to FP8, expert scales CSF-encoded with folded gate/up globals)"
      ;;
    *) return 1 ;;
  esac
}

# hyperflare_resolve_model VARIANT: the model for a known variant, else status 2
# with the variants that exist (the form every launcher's top-level wants).
hyperflare_resolve_model() {
  hyperflare_variant_model "$1" || {
    echo "error: unknown VARIANT '$1' (known: ${HYPERFLARE_VARIANTS[*]})" >&2
    return 2
  }
}
