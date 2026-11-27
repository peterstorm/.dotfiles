# shellcheck shell=bash
# The workstation gates every Hyperflare GLM-5.3 TP2 run script passes before it
# reserves both GPUs (run-glm53-flash-hyperflare-tp2-v16.sh, -v17.sh). Source it;
# it defines functions only.

# hyperflare_require_workstation SCRIPT_DIR: status 0 when desktop can host a TP2
# profile now: the declarative GPU power limit is pinned in
# machines/desktop/default.nix (found by walking up from SCRIPT_DIR) and every GPU
# runs at it, comfyui.service is not holding a GPU, and there are exactly two
# idle RTX PRO 6000 Blackwell cards. Otherwise status 1 with the reason on stderr.
hyperflare_require_workstation() {
  local nix_gpu_config='' walk_root="$1" declared_gpu_watts row index name memory_total memory_used power_limit
  local -a gpu_rows
  while [[ -z "$nix_gpu_config" && "$walk_root" != "/" ]]; do
    if [[ -f "$walk_root/machines/desktop/default.nix" ]]; then
      nix_gpu_config="$walk_root/machines/desktop/default.nix"
    else
      walk_root="$(dirname "$walk_root")"
    fi
  done
  [[ -n "$nix_gpu_config" ]] || { echo "error: no machines/desktop/default.nix found above $1" >&2; return 1; }
  declared_gpu_watts="$(sed -nE 's/^[[:space:]]*gpuPowerLimitWatts = ([0-9]+);$/\1/p' "$nix_gpu_config" | tail -1)"
  [[ -n "$declared_gpu_watts" ]] || { echo "error: gpuPowerLimitWatts is not pinned in $nix_gpu_config" >&2; return 1; }

  if systemctl is-active --quiet comfyui.service 2>/dev/null; then
    echo "error: comfyui.service is active; stop it before reserving both GPUs" >&2
    return 1
  fi
  mapfile -t gpu_rows < <(nvidia-smi --query-gpu=index,name,memory.total,memory.used,power.limit --format=csv,noheader,nounits)
  [ "${#gpu_rows[@]}" -eq 2 ] || { echo "error: this profile requires exactly two GPUs; found ${#gpu_rows[@]}" >&2; return 1; }
  for row in "${gpu_rows[@]}"; do
    IFS=, read -r index name memory_total memory_used power_limit <<<"$row"
    index="${index//[[:space:]]/}"; name="${name# }"
    memory_total="${memory_total//[[:space:]]/}"; memory_used="${memory_used//[[:space:]]/}"
    power_limit="${power_limit//[[:space:]]/}"
    [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || { echo "error: GPU $index is not an RTX PRO 6000 Blackwell: $name" >&2; return 1; }
    ((memory_total >= 97000)) || { echo "error: GPU $index exposes only ${memory_total} MiB" >&2; return 1; }
    ((memory_used <= 1024)) || { echo "error: GPU $index has ${memory_used} MiB in use; stop every GPU workload" >&2; return 1; }
    awk -v actual="$power_limit" -v declared="$declared_gpu_watts" \
      'BEGIN { exit !(actual >= declared - 0.5 && actual <= declared + 0.5) }' || {
        echo "error: GPU $index power limit is ${power_limit} W; declarative config pins ${declared_gpu_watts} W" >&2
        return 1
      }
  done
}

# hyperflare_require_free_endpoint: status 0 when nothing listens on :8000.
hyperflare_require_free_endpoint() {
  if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
    echo "error: host port 8000 is already listening; use switch-primary.sh to replace the active profile" >&2
    return 1
  fi
}
