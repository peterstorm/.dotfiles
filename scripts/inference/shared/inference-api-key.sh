#!/usr/bin/env bash
# shellcheck disable=SC2034 # This sourced helper intentionally publishes resolved values.
# Shared credential handling for the workstation's inference endpoints.
# Source this file; it deliberately performs no work by itself.

inference_resolve_operator() {
  local passwd_record

  if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    INFERENCE_OPERATOR_USER="$SUDO_USER"
    passwd_record="$(getent passwd "$INFERENCE_OPERATOR_USER")" || {
      echo "error: cannot resolve sudo operator: $INFERENCE_OPERATOR_USER" >&2
      return 1
    }
    IFS=: read -r _ _ _ _ _ INFERENCE_OPERATOR_HOME _ <<<"$passwd_record"
  else
    INFERENCE_OPERATOR_USER="$(id -un)"
    INFERENCE_OPERATOR_HOME="${HOME:?HOME is not set}"
  fi

  case "$INFERENCE_OPERATOR_HOME" in
    /*) ;;
    *) echo "error: operator home is not absolute: $INFERENCE_OPERATOR_HOME" >&2; return 1 ;;
  esac

  INFERENCE_OPERATOR_GROUP="$(id -gn "$INFERENCE_OPERATOR_USER")" || {
    echo "error: cannot resolve primary group for $INFERENCE_OPERATOR_USER" >&2
    return 1
  }
  INFERENCE_DS4_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/ds4-flash/api-key"
  INFERENCE_QWEN_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/qwen38/api-key"
  INFERENCE_GLM_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/api-key"
  INFERENCE_MUSE_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/muse-glimmer/api-key"
  INFERENCE_SOPS_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/sops-nix/secrets/vllm-api-key"
}

inference_install_private_dir() {
  local directory="$1"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    install -d -m 700 -o "$INFERENCE_OPERATOR_USER" -g "$INFERENCE_OPERATOR_GROUP" "$directory"
  else
    install -d -m 700 "$directory"
  fi
}

inference_secure_operator_file() {
  local path="$1"
  chmod 600 "$path"
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$path"
  fi
}

inference_write_private_file() {
  local destination="$1"
  local directory temporary
  directory="$(dirname "$destination")"
  temporary="$(mktemp "$directory/.${destination##*/}.tmp.XXXXXX")"
  chmod 600 "$temporary"

  if ! cat >"$temporary"; then
    rm -f "$temporary"
    echo "error: could not write private file: $destination" >&2
    return 1
  fi
  inference_secure_operator_file "$temporary"
  mv -f "$temporary" "$destination"
}

inference_require_cache_access() {
  local cache_path="$1" security_options
  if [ -w "$cache_path" ]; then
    return 0
  fi
  security_options="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null)" || {
    echo "error: cache directory is not writable and Docker mode cannot be determined: $cache_path" >&2
    return 1
  }
  if grep -Fq 'rootless' <<<"$security_options"; then
    echo "error: cache directory is not writable by the rootless Docker user: $cache_path" >&2
    return 1
  fi
  echo "Cache directory is root-owned; the rootful Docker daemon will access $cache_path."
}

inference_validate_api_key() {
  local key="$1"
  if [ -z "$key" ]; then
    echo "error: inference API key is empty" >&2
    return 1
  fi
  case "$key" in
    *$'\n'*|*$'\r'*)
      echo "error: inference API key contains a line break" >&2
      return 1
      ;;
    *[!A-Za-z0-9._~+/=-]*)
      echo "error: inference API key contains characters outside the bearer-token alphabet" >&2
      return 1
      ;;
  esac
  if [ "${#key}" -lt 32 ]; then
    echo "error: inference API key must contain at least 32 characters" >&2
    return 1
  fi
}

# Resolves one endpoint credential and synchronizes all model-specific key paths.
# Priority is explicit value -> DeepSeek key -> Qwen key -> GLM key -> Muse key ->
# sops fallback -> generated key. Pi uses the same order, so every launcher and client converges.
inference_prepare_api_key() {
  local explicit_key="${1:-}"
  local selected_key

  inference_resolve_operator
  # `install -d` creates intermediate components as the effective user. Repair
  # ~/.config unconditionally so an earlier sudo launch cannot leave it root-owned.
  inference_install_private_dir "$INFERENCE_OPERATOR_HOME/.config"
  inference_install_private_dir "$(dirname "$INFERENCE_DS4_KEYFILE")"
  inference_install_private_dir "$(dirname "$INFERENCE_QWEN_KEYFILE")"
  inference_install_private_dir "$(dirname "$INFERENCE_GLM_KEYFILE")"
  inference_install_private_dir "$(dirname "$INFERENCE_MUSE_KEYFILE")"

  if [ -n "$explicit_key" ]; then
    selected_key="$explicit_key"
  elif [ -r "$INFERENCE_DS4_KEYFILE" ]; then
    selected_key="$(<"$INFERENCE_DS4_KEYFILE")"
  elif [ -r "$INFERENCE_QWEN_KEYFILE" ]; then
    selected_key="$(<"$INFERENCE_QWEN_KEYFILE")"
  elif [ -r "$INFERENCE_GLM_KEYFILE" ]; then
    selected_key="$(<"$INFERENCE_GLM_KEYFILE")"
  elif [ -r "$INFERENCE_MUSE_KEYFILE" ]; then
    selected_key="$(<"$INFERENCE_MUSE_KEYFILE")"
  elif [ -r "$INFERENCE_SOPS_KEYFILE" ]; then
    selected_key="$(<"$INFERENCE_SOPS_KEYFILE")"
  else
    # 24 bytes encode to exactly 32 base64 characters (no padding).
    selected_key="$(head -c 24 /dev/urandom | base64 | tr -d '\n')"
  fi
  inference_validate_api_key "$selected_key"

  inference_write_private_file "$INFERENCE_DS4_KEYFILE" <<EOF
$selected_key
EOF
  inference_write_private_file "$INFERENCE_QWEN_KEYFILE" <<EOF
$selected_key
EOF
  inference_write_private_file "$INFERENCE_GLM_KEYFILE" <<EOF
$selected_key
EOF
  inference_write_private_file "$INFERENCE_MUSE_KEYFILE" <<EOF
$selected_key
EOF
  INFERENCE_API_KEY="$selected_key"
}

# Finds the key file Pi will choose without creating or modifying credentials.
inference_resolve_client_keyfile() {
  inference_resolve_operator
  if [ -r "$INFERENCE_DS4_KEYFILE" ]; then
    INFERENCE_CLIENT_KEYFILE="$INFERENCE_DS4_KEYFILE"
  elif [ -r "$INFERENCE_QWEN_KEYFILE" ]; then
    INFERENCE_CLIENT_KEYFILE="$INFERENCE_QWEN_KEYFILE"
  elif [ -r "$INFERENCE_GLM_KEYFILE" ]; then
    INFERENCE_CLIENT_KEYFILE="$INFERENCE_GLM_KEYFILE"
  elif [ -r "$INFERENCE_MUSE_KEYFILE" ]; then
    INFERENCE_CLIENT_KEYFILE="$INFERENCE_MUSE_KEYFILE"
  elif [ -r "$INFERENCE_SOPS_KEYFILE" ]; then
    INFERENCE_CLIENT_KEYFILE="$INFERENCE_SOPS_KEYFILE"
  else
    return 1
  fi
}
