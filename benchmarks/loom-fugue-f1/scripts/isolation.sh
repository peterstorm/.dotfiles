#!/usr/bin/env bash
# Install the pinned Loom runtime and remove cross-run memory packages for a batch.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTINGS="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json"
BACKUP="$SETTINGS.fugue-bench-backup"
LOOM_RUNTIME="$(realpath -e "${LOOM_RUNTIME_REPO:-$HOME/dev/claude-plugins/loom-benchmark-runtime-3815f65}")"
# shellcheck source=benchmarks/loom-fugue-f1/suite.sh
source "$BENCH_DIR/suite.sh"
EXPECTED_RUNTIME_SHA="$(fugue_source_lock_value "$BENCH_DIR" '.loom_runtime.base_sha')"

[[ -f "$SETTINGS" ]] || { echo "no Pi settings at $SETTINGS" >&2; exit 1; }
[[ "$(git -C "$LOOM_RUNTIME" rev-parse HEAD)" == "$EXPECTED_RUNTIME_SHA" ]] || {
  echo "pinned Loom runtime is unavailable at $LOOM_RUNTIME" >&2
  exit 1
}

packages() {
  node - "$SETTINGS" <<'NODE'
const fs = require("node:fs");
const settings = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
for (const value of settings.packages ?? []) console.log(value);
NODE
}

is_safe() {
  node - "$SETTINGS" "$LOOM_RUNTIME" <<'NODE'
const fs = require("node:fs");
const [file, runtime] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(file, "utf8"));
const packages = settings.packages ?? [];
const memoryActive = packages.some((value) => /(cortex|obsidian)/i.test(value));
const loomPackages = packages.filter((value) => /(^|\/)loom(?:\/)?$|loom-benchmark-runtime/i.test(value));
process.exit(!memoryActive && loomPackages.length === 1 && loomPackages[0] === runtime ? 0 : 1);
NODE
}

case "${1:-}" in
  status)
    echo "settings: $SETTINGS"
    echo 'packages:'
    packages | sed 's/^/  /'
    if ! is_safe; then
      echo "UNSAFE: memory packages are active or Pi is not registered to $LOOM_RUNTIME."
      exit 1
    fi
    echo "SAFE: memory packages are absent and Loom is pinned to $EXPECTED_RUNTIME_SHA."
    [[ -f "$BACKUP" ]] && echo "backup present: $BACKUP"
    ;;
  off)
    if is_safe; then
      echo 'Benchmark isolation is already active; nothing to do.'
      exit 0
    fi
    [[ ! -e "$BACKUP" ]] || { echo "backup already exists: $BACKUP" >&2; exit 1; }
    cp -p "$SETTINGS" "$BACKUP"
    node - "$SETTINGS" "$LOOM_RUNTIME" <<'NODE'
const fs = require("node:fs");
const [file, runtime] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(file, "utf8"));
const retained = [];
let insertedRuntime = false;
for (const value of settings.packages ?? []) {
  if (/(cortex|obsidian)/i.test(value)) continue;
  if (/(^|\/)loom(?:\/)?$|loom-benchmark-runtime/i.test(value)) {
    if (!insertedRuntime) retained.push(runtime);
    insertedRuntime = true;
    continue;
  }
  retained.push(value);
}
if (!insertedRuntime) retained.push(runtime);
settings.packages = retained;
fs.writeFileSync(file, `${JSON.stringify(settings, null, 2)}\n`);
NODE
    is_safe || { echo 'failed to establish benchmark isolation' >&2; exit 1; }
    echo "Cortex and Obsidian removed; Loom pinned to $EXPECTED_RUNTIME_SHA (backup: $BACKUP)."
    echo 'Start a fresh Pi process; do not reload an existing benchmark session.'
    ;;
  on)
    [[ -f "$BACKUP" ]] || { echo "no backup at $BACKUP" >&2; exit 1; }
    mv "$BACKUP" "$SETTINGS"
    echo "restored $SETTINGS"
    ;;
  *)
    echo "usage: $0 {status|off|on}" >&2
    exit 2
    ;;
esac
