#!/usr/bin/env bash
# Take cortex out of the loop for the duration of a benchmark batch.
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
# fact, so it is closed before the fact.
#
# Cortex is a global pi package, so this edits the global settings file and
# keeps a backup. Restore with `on` when the batch is finished.
set -euo pipefail

SETTINGS="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/settings.json"
BACKUP="$SETTINGS.bench-backup"
NEEDLE="cortex"

[[ -f "$SETTINGS" ]] || { echo "no pi settings at $SETTINGS" >&2; exit 1; }

packages() { node -e '
  const s = require(process.argv[1]);
  console.log((s.packages ?? []).join("\n"));
' "$SETTINGS"; }

case "${1:-}" in
  status)
    echo "settings: $SETTINGS"
    echo "packages:"
    packages | sed 's/^/  /'
    if packages | grep -q "$NEEDLE"; then
      echo
      echo "CORTEX IS ACTIVE — runs started now are contaminated across arms."
    else
      echo
      echo "cortex not registered — safe to run."
    fi
    [[ -f "$BACKUP" ]] && echo "backup present: $BACKUP (run 'on' to restore)"
    exit 0
    ;;

  off)
    if ! packages | grep -q "$NEEDLE"; then
      echo "cortex already absent; nothing to do."
      exit 0
    fi
    [[ -f "$BACKUP" ]] && { echo "backup already exists at $BACKUP — refusing to overwrite it" >&2; exit 1; }
    cp -p "$SETTINGS" "$BACKUP"
    node -e '
      const fs = require("fs");
      const [file, needle] = process.argv.slice(1);
      const s = JSON.parse(fs.readFileSync(file, "utf8"));
      s.packages = (s.packages ?? []).filter((p) => !p.includes(needle));
      fs.writeFileSync(file, `${JSON.stringify(s, null, 2)}\n`);
    ' "$SETTINGS" "$NEEDLE"
    echo "cortex removed from $SETTINGS (backup: $BACKUP)"
    echo "Run /reload in any open pi session, or start a fresh one."
    ;;

  on)
    [[ -f "$BACKUP" ]] || { echo "no backup at $BACKUP — restore packages by hand" >&2; exit 1; }
    mv "$BACKUP" "$SETTINGS"
    echo "restored $SETTINGS"
    ;;

  *)
    echo "usage: $0 {status|off|on}" >&2
    exit 2
    ;;
esac
