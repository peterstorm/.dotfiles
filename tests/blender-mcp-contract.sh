#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/machines/desktop/blender-previz.nix"
DESKTOP="$ROOT/machines/desktop/default.nix"
GLOBAL_SETTINGS="$ROOT/pi/settings.json"
PROJECT_SETTINGS="$ROOT/pi/project-config/creative/settings.json"
MCP_CONFIG="$ROOT/pi/project-config/creative/mcp.json"
SKILL="$ROOT/pi/project-skills/creative/blender-previz/SKILL.md"
WORKFLOW="$ROOT/pi/project-skills/creative/blender-previz/references/workflow.md"
HOME_MODULE="$ROOT/roles/home-manager/core-apps/pi/default.nix"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for file in "$MODULE" "$DESKTOP" "$GLOBAL_SETTINGS" "$PROJECT_SETTINGS" "$MCP_CONFIG" "$SKILL" "$WORKFLOW" "$HOME_MODULE"; do
  [[ -f "$file" ]] || fail "missing $file"
done

nix-instantiate --parse "$MODULE" >/dev/null
nix-instantiate --parse "$DESKTOP" >/dev/null
nix-instantiate --parse "$HOME_MODULE" >/dev/null
contains "$DESKTOP" './blender-previz.nix'
jq -e '.packages | map(if type == "object" then .source else . end) | index("git:github.com/nicobailon/pi-mcp-adapter@ff234b862359e722bf4dc1c99cde62278d4b8eb3") != null' "$PROJECT_SETTINGS" >/dev/null \
  || fail "creative-project Pi MCP adapter is not revision-pinned"
jq -e '.packages | map(if type == "object" then .source else . end) | index("git:github.com/nicobailon/pi-mcp-adapter@ff234b862359e722bf4dc1c99cde62278d4b8eb3") == null' "$GLOBAL_SETTINGS" >/dev/null \
  || fail "Pi MCP adapter must not be globally installed"
jq -e '
  .settings.scriptMode == false and
  .mcpServers.blender.command == "ssh" and
  (.mcpServers.blender.args | index("desktop") != null) and
  (.mcpServers.blender.args | index("DISABLE_TELEMETRY=true") != null) and
  .mcpServers.blender.approveTools == ["execute_blender_code"] and
  (.mcpServers.blender.includeTools | sort) == ([
    "execute_blender_code",
    "get_object_info",
    "get_scene_info",
    "get_viewport_screenshot"
  ] | sort)
' "$MCP_CONFIG" >/dev/null || fail "Blender MCP config violates the local allowlist"
contains "$HOME_MODULE" '"blender-previz"'
contains "$HOME_MODULE" '"dev/creative/.pi/settings.json"'
contains "$HOME_MODULE" '"dev/creative/.mcp.json"'

contains "$MODULE" 'version = "1.9.0";'
contains "$MODULE" 'f0759291b5748c35fcdabd68f89b684cfaae6c61dd475f87d591dddcef63f9fa'
contains "$MODULE" 'dependencies = with pkgs.python3Packages;'
contains "$MODULE" '      httpx'
contains "$MODULE" '      mcp'
contains "$MODULE" 'default=True,'
contains "$MODULE" 'default=False,'
contains "$MODULE" 'DISABLE_TELEMETRY=true'
contains "$MODULE" 'BLENDER_USER_SCRIPTS'
contains "$MODULE" 'blender-mcp-session'
contains "$MODULE" 'pkgs.blender'
contains "$MODULE" 'pkgs.xvfb'
contains "$MODULE" 'Xvfb -displayfd 3 -screen 0 1920x1080x24 -nolisten tcp'
contains "$MODULE" 'blenderMcpServer'

contains "$SKILL" 'name: blender-previz'
contains "$SKILL" 'MCP is the live authoring surface'
contains "$SKILL" 'one shot per `.blend`'
contains "$SKILL" 'contact sheet before animation'
contains "$SKILL" 'never acting authority'
contains "$SKILL" 'carrier contract'
contains "$SKILL" 'Render targets come from the shot unit'
contains "$WORKFLOW" 'reference → mechanism reconstruction → original remix'
contains "$WORKFLOW" 'CARRIER-CONTRACT.md'
contains "$WORKFLOW" 'setup → load → event/contact → consequence'
contains "$WORKFLOW" 'Pi runs on `homelab`; Blender runs on `desktop`'
[[ ! -e "$ROOT/pi/skills/blender-previz" ]] || fail "Blender previz must not be a global Pi skill"

printf 'PASS: Blender MCP is pinned, loopback-scoped, telemetry-off, Pi-discoverable, and bounded at the blocking-video handoff\n'
