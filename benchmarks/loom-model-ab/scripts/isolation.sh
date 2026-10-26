#!/usr/bin/env bash
# Take memory out of the loop for the duration of a benchmark batch.
#
#   bash scripts/isolation.sh status
#   bash scripts/isolation.sh off     # before the first run
#   bash scripts/isolation.sh on      # after the last run
#
# Why this exists: cortex recalls into every session and extracts from every
# transcript. Left on, arm 1's design decisions are recalled as authoritative
# context inside arm 2 — and because the injection arrives inside a
# <system-reminder>, it leaves no trace in the diff, the artifacts, or the
# grade. It is the one contamination channel that cannot be caught after the
# fact, so it is closed before the fact. The Obsidian vault is the long-term
# half of the same memory, so it leaves with cortex.
#
# Memory packages are global pi packages, so this edits the global settings
# file and keeps a backup. `off` also snapshots the rendered phase agents,
# because run-arm.sh re-renders them bound to the arm's model and pinned Loom
# runtime. Restore both with `on` when the batch is finished.
#
# With LOOM_RUNTIME_REPO set, `off` also points the Loom package entry at that
# pinned runtime: Pi's subagent extension resolves child skills from package
# sources, so leaving the entry on a live checkout would mix two Loom versions.
set -euo pipefail

PI_AGENT_ROOT="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
SETTINGS="$PI_AGENT_ROOT/settings.json"
BACKUP="$SETTINGS.bench-backup"
AGENTS="$PI_AGENT_ROOT/agents"
AGENTS_BACKUP="$AGENTS.bench-backup"

[[ -f "$SETTINGS" ]] || { echo "no pi settings at $SETTINGS" >&2; exit 1; }

# One source string per package. Entries are either a bare source string or
# an object whose `source` names it (e.g. a package with filtered extensions).
packages() { node -e '
  const s = require(process.argv[1]);
  for (const p of s.packages ?? []) console.log(typeof p === "string" ? p : p.source);
' "$SETTINGS"; }

memory_packages() { packages | grep -E '(^|/)(cortex|obsidian)/?$' || true; }

case "${1:-}" in
  status)
    echo "settings: $SETTINGS"
    echo "packages:"
    packages | sed 's/^/  /'
    echo
    if [[ -n "$(memory_packages)" ]]; then
      echo "MEMORY IS ACTIVE — runs started now are contaminated across arms."
    else
      echo "no memory package registered — safe to run."
    fi
    [[ -f "$BACKUP" ]] && echo "settings backup present: $BACKUP (run 'on' to restore)"
    [[ -d "$AGENTS_BACKUP" ]] && echo "agents backup present: $AGENTS_BACKUP (run 'on' to restore)"
    exit 0
    ;;

  off)
    if [[ -z "$(memory_packages)" ]]; then
      echo "memory packages already absent; nothing to do."
      exit 0
    fi
    [[ -f "$BACKUP" ]] && { echo "backup already exists at $BACKUP — refusing to overwrite it" >&2; exit 1; }
    [[ -e "$AGENTS_BACKUP" ]] && { echo "backup already exists at $AGENTS_BACKUP — refusing to overwrite it" >&2; exit 1; }
    cp -p "$SETTINGS" "$BACKUP"
    [[ -d "$AGENTS" ]] && cp -a "$AGENTS" "$AGENTS_BACKUP"
    RUNTIME=''
    [[ -n "${LOOM_RUNTIME_REPO:-}" ]] && RUNTIME="$(cd "$LOOM_RUNTIME_REPO" && pwd)"
    node -e '
      const fs = require("fs");
      const [file, runtime] = process.argv.slice(1);
      const s = JSON.parse(fs.readFileSync(file, "utf8"));
      const source = (p) => (typeof p === "string" ? p : p.source);
      const pin = (p) => {
        if (!runtime || !/(^|\/)loom\/?$/.test(source(p))) return p;
        return typeof p === "string" ? runtime : { ...p, source: runtime };
      };
      s.packages = (s.packages ?? [])
        .filter((p) => !/(^|\/)(cortex|obsidian)\/?$/.test(source(p)))
        .map(pin);
      fs.writeFileSync(file, `${JSON.stringify(s, null, 2)}\n`);
    ' "$SETTINGS" "$RUNTIME"
    echo "memory packages removed from $SETTINGS (backup: $BACKUP)"
    [[ -n "$RUNTIME" ]] && echo "Loom package pinned to $RUNTIME"
    [[ -d "$AGENTS_BACKUP" ]] && echo "rendered agents snapshotted to $AGENTS_BACKUP"
    echo "Run /reload in any open pi session, or start a fresh one."
    ;;

  on)
    [[ -f "$BACKUP" ]] || { echo "no backup at $BACKUP — restore packages by hand" >&2; exit 1; }
    mv "$BACKUP" "$SETTINGS"
    echo "restored $SETTINGS"
    if [[ -d "$AGENTS_BACKUP" ]]; then
      rm -rf "$AGENTS"
      mv "$AGENTS_BACKUP" "$AGENTS"
      echo "restored $AGENTS"
    fi
    ;;

  *)
    echo "usage: $0 {status|off|on}" >&2
    exit 2
    ;;
esac
