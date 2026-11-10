#!/usr/bin/env bash
# Build an isolated Pi root for one benchmark batch, without touching the live
# ~/.pi/agent configuration.
#
#   bash scripts/pi-root.sh create          # build/refresh the root + pinned Loom runtime
#   bash scripts/pi-root.sh env             # print the env a benchmark Pi needs
#   bash scripts/pi-root.sh trust <path>    # trust one worktree in the isolated root
#   bash scripts/pi-root.sh status
#   bash scripts/pi-root.sh remove
#
# Why a separate root instead of flipping the live settings (isolation.sh):
# the live file also configures the operator's own sessions, and a forgotten
# `on` leaves memory packages off. Here the contamination channels are closed
# by construction:
#
#   * packages = exactly one entry, the pinned Loom runtime — no Cortex recall
#     or extraction, no Obsidian vault;
#   * Loom is a detached checkout at the recorded base commit, so uncommitted
#     edits in the operator's working checkout cannot change agent prompts or
#     engine behaviour mid-batch;
#   * agents/, sessions/, cache/ are private; run-arm.sh renders the phase agents
#     into this root bound to the arm's model (and refuses to continue unless the
#     render names the pinned runtime), and the transcript lands at a predictable
#     path.
#
# Everything the model needs to *run* is shared by symlink: the extension set
# (subagent transport, model routing, loom loader), prompts, skills, the model
# catalog and routing policy. Omitting the subagent extension voids a run — the
# first Qwen v2 attempt proved that — so it is asserted, not hoped for.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOM="${LOOM_REPO:-$HOME/dev/claude-plugins/loom}"
LIVE_ROOT="${LIVE_PI_ROOT:-$HOME/.pi/agent}"
BENCH_ROOT="${BENCH_PI_ROOT:-$HOME/.pi/bench-agent}"
# shellcheck source=benchmarks/loom-model-ab/scripts/worktree-deps.sh
source "$BENCH_DIR/scripts/worktree-deps.sh"

BASE_SHA="$(git -C "$LOOM" rev-parse HEAD)"
RUNTIME="${LOOM_BENCH_RUNTIME:-$LOOM/../loom-benchmark-runtime-${BASE_SHA:0:7}}"

die() { echo "pi-root: $*" >&2; exit 1; }

link() { # link <name> — share one live entry by symlink, if it exists
  [[ -e "$LIVE_ROOT/$1" ]] || return 0
  ln -sfn "$(realpath "$LIVE_ROOT/$1")" "$BENCH_ROOT/$1"
}

create() {
  [[ -d "$LIVE_ROOT/extensions" ]] || die "no extensions directory under $LIVE_ROOT"
  [[ -f "$LIVE_ROOT/extensions/subagent/index.ts" ]] || die "live Pi has no subagent extension; a run would be void"

  if [[ ! -d "$RUNTIME" ]]; then
    git -C "$LOOM" worktree add --detach "$RUNTIME" "$BASE_SHA" >/dev/null
  fi
  RUNTIME="$(cd "$RUNTIME" && pwd -P)"
  [[ "$(git -C "$RUNTIME" rev-parse HEAD)" == "$BASE_SHA" ]] \
    || die "$RUNTIME is not at Loom HEAD $BASE_SHA; remove it and re-run create"
  [[ -e "$RUNTIME/node_modules" || ! -d "$LOOM/node_modules" ]] || ln -s "$LOOM/node_modules" "$RUNTIME/node_modules"
  benchmark_overlay_node_modules "$LOOM" "$RUNTIME"

  mkdir -p "$BENCH_ROOT"
  for entry in extensions prompts skills bin model-routing.json; do link "$entry"; done
  # The catalog is copied, not linked: it is frozen for the batch, and nothing
  # the benchmark does can write through to the operator's live file.
  cp -f "$LIVE_ROOT/models.json" "$BENCH_ROOT/models.json"
  [[ -e "$BENCH_ROOT/trust.json" ]] || echo '{}' > "$BENCH_ROOT/trust.json"

  node - "$BENCH_ROOT/settings.json" "$RUNTIME" "$LIVE_ROOT/settings.json" <<'NODE'
const fs = require("node:fs");
const [out, runtime, live] = process.argv.slice(2);
const base = fs.existsSync(live) ? JSON.parse(fs.readFileSync(live, "utf8")) : {};
// Keep presentation/model defaults; replace the package list wholesale.
const { packages: _drop, ...rest } = base;
fs.writeFileSync(out, `${JSON.stringify({ ...rest, packages: [{ source: runtime, extensions: [] }] }, null, 2)}\n`);
NODE
  echo "isolated Pi root: $BENCH_ROOT"
  echo "pinned Loom runtime: $RUNTIME @ $BASE_SHA"
}

env_lines() {
  [[ -f "$BENCH_ROOT/settings.json" ]] || die "no isolated root; run: $0 create"
  local runtime
  runtime="$(node -e 'const s=require(process.argv[1]); console.log(s.packages[0].source)' "$BENCH_ROOT/settings.json")"
  printf 'export PI_CODING_AGENT_DIR=%q\n' "$BENCH_ROOT"
  printf 'export LOOM_RUNTIME_LOADER_ROOT=%q\n' "$runtime"
}

status() {
  [[ -f "$BENCH_ROOT/settings.json" ]] || { echo "no isolated root at $BENCH_ROOT"; return 1; }
  node - "$BENCH_ROOT/settings.json" "$BENCH_ROOT" <<'NODE'
const fs = require("node:fs");
const [file, root] = process.argv.slice(2);
const settings = JSON.parse(fs.readFileSync(file, "utf8"));
const packages = (settings.packages ?? []).map((p) => (typeof p === "string" ? p : p.source));
const memory = packages.filter((p) => /(cortex|obsidian)/i.test(p));
console.log(`root: ${root}\npackages:\n${packages.map((p) => `  ${p}`).join("\n")}`);
for (const need of ["extensions/subagent/index.ts", "model-routing.json", "models.json"]) {
  console.log(`${fs.existsSync(`${root}/${need}`) ? "ok     " : "MISSING"} ${need}`);
}
if (memory.length > 0 || packages.length !== 1) { console.log("UNSAFE: memory package present or package list is not exactly the pinned runtime"); process.exit(1); }
console.log("SAFE: no memory packages; Loom pinned.");
NODE
}

trust() {
  local path="${1:-}"
  [[ -n "$path" && -d "$path" ]] || die "usage: $0 trust <existing directory>"
  node - "$BENCH_ROOT/trust.json" "$(cd "$path" && pwd -P)" <<'NODE'
const fs = require("node:fs");
const [file, dir] = process.argv.slice(2);
const trust = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : {};
fs.writeFileSync(file, `${JSON.stringify({ ...trust, [dir]: true }, null, 2)}\n`);
NODE
}

case "${1:-}" in
  create) create ;;
  env) env_lines ;;
  status) status ;;
  trust) shift; trust "${1:-}" ;;
  remove)
    rm -rf "$BENCH_ROOT"
    echo "removed $BENCH_ROOT (runtime checkout kept: $RUNTIME)"
    ;;
  *) echo "usage: $0 {create|env|status|trust <path>|remove}" >&2; exit 2 ;;
esac
