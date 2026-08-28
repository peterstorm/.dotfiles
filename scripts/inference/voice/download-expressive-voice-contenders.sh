#!/usr/bin/env bash
# Download immutable expressive-TTS model closures without starting a GPU runtime.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${EXPRESSIVE_VOICE_MANIFEST:-$SCRIPT_DIR/expressive-voice-contenders.manifest.tsv}"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"
RESTRICTED_LICENSE_ACCEPTANCE="${EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES:-}"
DOWNLOAD_AUTHORIZATION="${EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION:-}"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

profile_record() {
  local slug="$1"
  awk -F '\t' -v slug="$slug" '$1 == "profile" && $2 == slug { print $3 "\t" $4 "\t" $5 "\t" $6 }' "$MANIFEST_FILE"
}

artifact_manifest() {
  local slug="$1"
  awk -F '\t' -v slug="$slug" '$1 == "artifact" && $2 == slug { print $3 "\t" $4 "\t" $5 }' "$MANIFEST_FILE"
}

profile_slugs() {
  awk -F '\t' '$1 == "profile" { print $2 }' "$MANIFEST_FILE"
}

parse_profile() {
  local slug="$1" record field_count
  record="$(profile_record "$slug")"
  [[ -n "$record" ]] || fail "unknown contender profile: $slug"
  field_count="$(awk -F '\t' 'NF { print NF }' <<<"$record")"
  [[ "$field_count" == 4 ]] || fail "profile is not unique or malformed: $slug"
  printf '%s\n' "$record"
}

profile_is_restricted() {
  case "$1" in
    apache-2.0-commercial-candidate|apache-2.0-dramabox-runtime-dependency|nvidia-source-code-license-dramabox-optional-denoiser|apache-2.0-lineage-review-required)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

verify_manifest() {
  local root="$1" slug="$2" expected_sha expected_size relative file actual_sha actual_size
  while IFS=$'\t' read -r expected_sha expected_size relative; do
    [[ -n "$relative" ]] || continue
    file="$root/$relative"
    [[ -f "$file" && ! -L "$file" ]] || { printf 'missing or non-regular: %s\n' "$relative" >&2; return 1; }
    actual_size="$(stat -c %s "$file")"
    [[ "$actual_size" == "$expected_size" ]] || {
      printf 'size mismatch: %s (expected %s, got %s)\n' "$relative" "$expected_size" "$actual_size" >&2
      return 1
    }
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    [[ "$actual_sha" == "$expected_sha" ]] || { printf 'checksum mismatch: %s\n' "$relative" >&2; return 1; }
  done < <(artifact_manifest "$slug")
}

verify_exact_file_set() {
  local root="$1" slug="$2" expected actual status=0
  expected="$(mktemp)"
  actual="$(mktemp)"
  artifact_manifest "$slug" | cut -f3 | LC_ALL=C sort >"$expected"
  find "$root" -type f -printf '%P\n' | LC_ALL=C sort >"$actual"
  if ! cmp -s "$expected" "$actual"; then
    printf 'repository file set mismatch for %s\n' "$slug" >&2
    diff -u "$expected" "$actual" >&2 || true
    status=1
  fi
  rm -f "$expected" "$actual"
  return "$status"
}

stage_verified_existing() {
  local destination="$1" staging="$2" slug="$3"
  local expected_sha expected_size relative source target actual_sha actual_size
  while IFS=$'\t' read -r expected_sha expected_size relative; do
    [[ -n "$relative" ]] || continue
    target="$staging/$relative"
    if [[ -f "$target" && ! -L "$target" ]]; then
      actual_size="$(stat -c %s "$target")"
      actual_sha="$(sha256sum "$target" | cut -d' ' -f1)"
      if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
        continue
      fi
      rm -f "$target"
    fi
    source="$destination/$relative"
    if [[ -f "$source" && ! -L "$source" ]]; then
      actual_size="$(stat -c %s "$source")"
      actual_sha="$(sha256sum "$source" | cut -d' ' -f1)"
      if [[ "$actual_size" == "$expected_size" && "$actual_sha" == "$expected_sha" ]]; then
        mkdir -p "$(dirname -- "$target")"
        cp --reflink=auto --preserve=mode,timestamps "$source" "$target"
      fi
    fi
  done < <(artifact_manifest "$slug")
}

download_artifact() {
  local repository="$1" revision="$2" staging="$3" expected_sha="$4" expected_size="$5" relative="$6"
  local target="$staging/$relative" partial="$staging/$relative.part" actual_sha actual_size
  [[ -f "$target" ]] && return 0
  mkdir -p "$(dirname -- "$target")"
  curl --location --fail --show-error \
    --retry 20 --retry-all-errors --retry-delay 5 --connect-timeout 30 \
    --continue-at - --output "$partial" \
    "https://huggingface.co/$repository/resolve/$revision/$relative"
  actual_size="$(stat -c %s "$partial")"
  actual_sha="$(sha256sum "$partial" | cut -d' ' -f1)"
  if [[ "$actual_size" != "$expected_size" || "$actual_sha" != "$expected_sha" ]]; then
    printf 'download verification failed: %s (expected %s/%s, got %s/%s)\n' \
      "$relative" "$expected_size" "$expected_sha" "$actual_size" "$actual_sha" >&2
    rm -f "$partial"
    exit 1
  fi
  mv "$partial" "$target"
}

download_profile_artifacts() {
  local repository="$1" revision="$2" staging="$3" slug="$4"
  local expected_sha expected_size relative
  while IFS=$'\t' read -r expected_sha expected_size relative; do
    [[ -n "$relative" ]] || continue
    download_artifact "$repository" "$revision" "$staging" "$expected_sha" "$expected_size" "$relative"
  done < <(artifact_manifest "$slug")
}

write_receipt() {
  local destination="$1" slug="$2" repository="$3" revision="$4" usage_scope="$5" repository_bytes="$6" manifest_sha="$7"
  cat >"$destination/download-receipt.json" <<EOF
{
  "schemaVersion": 1,
  "profile": "$slug",
  "repository": "$repository",
  "revision": "$revision",
  "usageScope": "$usage_scope",
  "repositoryBytes": $repository_bytes,
  "manifestSha256": "$manifest_sha",
  "downloadAuthorization": "$DOWNLOAD_AUTHORIZATION",
  "gpuRuntimeStarted": false,
  "productionAuthority": false
}
EOF
}

write_completion_marker() {
  local marker="$1" repository="$2" revision="$3" usage_scope="$4" manifest_sha="$5"
  local marker_tmp="$marker.new"
  {
    printf '%s@%s\n' "$repository" "$revision"
    printf 'usage-scope=%s\n' "$usage_scope"
    printf 'manifest-sha256=%s\n' "$manifest_sha"
    printf 'download-authorization=%s\n' "$DOWNLOAD_AUTHORIZATION"
    printf 'gpu-runtime-started=false\n'
    printf 'production-authority=false\n'
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv "$marker_tmp" "$marker"
}

download_profile() {
  local slug="$1" record repository revision usage_scope repository_bytes
  local destination staging marker manifest_sha lock_fd
  exec {lock_fd}>"$MODELS_ROOT/.$slug.lock"
  flock "$lock_fd"
  record="$(parse_profile "$slug")"
  IFS=$'\t' read -r repository revision usage_scope repository_bytes <<<"$record"
  destination="$MODELS_ROOT/$slug"
  staging="$MODELS_ROOT/.staging-$slug"
  marker="$MODELS_ROOT/.$slug.complete"
  manifest_sha="$(artifact_manifest "$slug" | sha256sum | cut -d' ' -f1)"

  if [[ -f "$marker" ]] \
      && grep -Fxq "$repository@$revision" "$marker" \
      && grep -Fxq "manifest-sha256=$manifest_sha" "$marker" \
      && verify_manifest "$destination" "$slug"; then
    printf 'EXPRESSIVE_VOICE_MODEL_READY: %s\n' "$destination"
    exec {lock_fd}>&-
    return 0
  fi
  [[ ! -e "$destination" ]] || fail "unverified immutable destination already exists: $destination"

  mkdir -p "$staging"
  stage_verified_existing "$destination" "$staging" "$slug"
  download_profile_artifacts "$repository" "$revision" "$staging" "$slug"
  verify_manifest "$staging" "$slug"
  rm -rf "$staging/.cache"
  find "$staging" -type l -print -quit | grep -q . && fail "symlink found in staged closure: $slug"
  verify_exact_file_set "$staging" "$slug"

  artifact_manifest "$slug" | awk -F '\t' '{ print $1 "  " $3 }' >"$staging/ARTIFACTS.sha256"
  write_receipt "$staging" "$slug" "$repository" "$revision" "$usage_scope" "$repository_bytes" "$manifest_sha"
  chmod -R u=rwX,g=rX,o= "$staging"
  mv "$staging" "$destination"
  write_completion_marker "$marker" "$repository" "$revision" "$usage_scope" "$manifest_sha"
  verify_manifest "$destination" "$slug"
  printf 'EXPRESSIVE_VOICE_MODEL_READY: %s\n' "$destination"
  exec {lock_fd}>&-
}

main() {
  local -a selected=()
  local slug record usage_scope required_bytes=0 available_bytes
  for dependency in awk cmp cp curl cut diff find flock grep mktemp sha256sum sort stat; do
    command -v "$dependency" >/dev/null 2>&1 || fail "missing command: $dependency"
  done
  [[ -s "$MANIFEST_FILE" ]] || fail "missing manifest: $MANIFEST_FILE"
  [[ "$DOWNLOAD_AUTHORIZATION" == user-request-2026-08-28 ]] \
    || fail 'set EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28'

  if (( $# == 0 )); then
    mapfile -t selected < <(profile_slugs)
  else
    selected=("$@")
  fi
  (( ${#selected[@]} > 0 )) || fail 'no contender profiles selected'

  for slug in "${selected[@]}"; do
    record="$(parse_profile "$slug")"
    IFS=$'\t' read -r _ _ usage_scope repository_bytes <<<"$record"
    if profile_is_restricted "$usage_scope" && [[ "$RESTRICTED_LICENSE_ACCEPTANCE" != yes ]]; then
      fail "restricted profile requires EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes: $slug ($usage_scope)"
    fi
    required_bytes=$((required_bytes + repository_bytes))
  done

  mkdir -p "$MODELS_ROOT"
  available_bytes="$(df -PB1 "$MODELS_ROOT" | awk 'NR == 2 { print $4 }')"
  (( available_bytes > required_bytes + 10737418240 )) \
    || fail "insufficient free space: need model bytes plus 10 GiB headroom"

  for slug in "${selected[@]}"; do
    download_profile "$slug"
  done
  printf 'EXPRESSIVE_VOICE_CONTENDERS_READY: profiles=%s\n' "${#selected[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
