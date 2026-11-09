#!/usr/bin/env bash
# Make a fresh Loom worktree runnable on this host.
#
# Loom tracks a Linux-built engine/node_modules in Git. A worktree therefore
# lacks every package that is untracked (jsonc-parser, saxes, ...) and carries
# the wrong native binaries (rollup, esbuild) on macOS, so `tsc` and `vitest`
# fail at the frozen baseline on files nobody touched — the instrument would
# then measure the host, not the model.
#
# The live checkout holds a working install for this host. Clone it into the
# worktree (copy-on-write where the filesystem supports it) and mark the tracked
# paths skip-worktree so the planning-only grader still sees "no file changed".
#
# Sourced by baseline.sh and run-arm.sh. Defines functions only.

benchmark_overlay_node_modules() {
  local live="${1:-}" worktree="${2:-}"
  [[ -d "$live/engine/node_modules" ]] || return 0
  [[ -d "$worktree/engine" ]] || { echo "not a Loom worktree: ${worktree:-<empty>}" >&2; return 2; }
  # Never overlay the live checkout onto itself.
  [[ "$(cd "$live" && pwd -P)" != "$(cd "$worktree" && pwd -P)" ]] || return 0

  # APFS clones (-c) exist only on the system cp; a GNU cp earlier on PATH
  # (scripts/gnu.sh) would reject the flag, so name the system binary.
  local copy=(cp -R --reflink=auto)
  [[ "$(uname -s)" != Darwin ]] || copy=(/bin/cp -Rc)
  # Tracked paths first: copying over them is a content change to be hidden.
  git -C "$worktree" ls-files -z -- engine/node_modules \
    | xargs -0 git -C "$worktree" update-index --skip-worktree
  rm -rf "$worktree/engine/node_modules"
  "${copy[@]}" "$live/engine/node_modules" "$worktree/engine/node_modules"
}
