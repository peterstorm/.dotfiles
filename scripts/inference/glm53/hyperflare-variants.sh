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
#   cyber-hybrid  v16's checkpoint with the dense tensors of dealignai's
#                 GLM-5.3-Flash-CYBERSECURITY build spliced in by
#                 glm-hybrid-checkpoint.py. The routed experts, the vision tower
#                 and every quantization declaration are v16's, so one package
#                 shape (and one launcher) serves both.
#   cyber-hybrid-bf16  v16's checkpoint (built with --base glm53-fp4-local) carrying
#                 only the splice's requantized dense tensors from layer 40 on plus
#                 lm_head, stored as the donor's plain BF16 instead of FP8
#                 (glm53-bf16-dense.py). Layers 0-39 and the splice's copy/cast
#                 tensors stay v16's. Tests whether the late edit alone, without the
#                 requant, holds up in long generation; the loader serves plain BF16
#                 projections natively.
#
# Adding a variant is one line in each case below; an unknown variant is a
# status, never a guess.

HYPERFLARE_VARIANTS=(v16 cyber-hybrid cyber-hybrid-bf16)

# hyperflare_variant_model VARIANT: the checkpoint directory, which Hyperflare
# also uses as the model name. Status 1 for a variant that does not exist.
hyperflare_variant_model() {
  case "$1" in
    v16) echo glm53-fp4-local ;;
    cyber-hybrid) echo glm53-cyber-hybrid ;;
    cyber-hybrid-bf16) echo glm53-cyber-hybrid-bf16 ;;
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
    cyber-hybrid)
      echo "$2 + dealignai/GLM-5.3-Flash-CYBERSECURITY-W4A16@4c2ee763ff75f3ba50652ee0f024b0b630cd54a0 (dense tensors)"
      ;;
    cyber-hybrid-bf16)
      echo "$2 + dealignai/GLM-5.3-Flash-CYBERSECURITY-W4A16@4c2ee763ff75f3ba50652ee0f024b0b630cd54a0 (late-layer + lm_head requantized dense tensors only, BF16)"
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
