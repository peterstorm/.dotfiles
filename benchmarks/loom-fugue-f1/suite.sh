#!/usr/bin/env bash
# shellcheck disable=SC2034 # Public catalog constants are consumed by sourced callers.
# Pure catalog for the Fugue F1 runtime-width fan-out planning benchmark.
# Callers own all I/O; this file only names immutable suite artifacts.

FUGUE_SUITE_ID='fugue-f1-map-v1'
FUGUE_PROTOCOL_VERSION='v1'
FUGUE_PROTOCOL_FILES=(
  source-lock.json
  frozen/brief.md
  frozen/answer-key.md
  hidden/reference-spec.md
  hidden/acceptance-scenarios.md
  rubric.md
)

fugue_protocol_files() {
  printf '%s\n' "${FUGUE_PROTOCOL_FILES[@]}"
}

fugue_protocol_manifest() {
  local bench_dir="${1:-}"
  [[ -d "$bench_dir" ]] || {
    printf 'benchmark directory is not readable: %s\n' "${bench_dir:-<empty>}" >&2
    return 2
  }
  (cd "$bench_dir" && sha256sum "${FUGUE_PROTOCOL_FILES[@]}")
}

fugue_protocol_sha() {
  fugue_protocol_manifest "$1" | sha256sum | cut -d' ' -f1
}

fugue_source_lock_value() {
  local bench_dir="${1:-}" query="${2:-}"
  [[ -r "$bench_dir/source-lock.json" ]] || {
    printf 'source lock is not readable: %s/source-lock.json\n' "$bench_dir" >&2
    return 2
  }
  [[ -n "$query" ]] || { echo 'jq query is required' >&2; return 2; }
  jq -er "$query" "$bench_dir/source-lock.json"
}
