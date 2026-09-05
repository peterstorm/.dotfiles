{ pkgs, ... }:

let
  # Blender MCP has two processes by design: Blender's reviewed add-on owns a
  # loopback-only socket inside the GUI, while this stdio server is launched by
  # Pi through `ssh desktop`. Pin the published wheel rather than mutable PyPI
  # metadata; the wheel also contains the exact add-on paired with its protocol.
  #
  # 1.9.1 adds an opt-in AST allowlist for `execute_blender_code`
  # (`BLENDER_MCP_SAFE_MODE=1`). It stays off here by choice, not by oversight:
  # it exists to blunt prompt injection arriving through third-party asset
  # catalogues, and every asset provider is already disabled in the add-on and
  # excluded from the `.mcp.json` tool allowlist, while the tool that remains is
  # approval-gated. Its policy would also reject importing the skill's own
  # trajectory module and defining classes inside scene scripts. Enable it in
  # the `.mcp.json` ssh env for any session that consumes untrusted text.
  blenderMcpServer = pkgs.python3Packages.buildPythonApplication {
    pname = "blender-mcp";
    version = "1.9.1";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/98/93/3e8656c0436c7df6397775064cc05261910c05be009c598d38dda0eda816/blender_mcp-1.9.1-py3-none-any.whl";
      hash = "sha256-7eOu00km93FCuPAO5PhUT2gGfS3HR9qCldHEVhcTVbI="; # ede3aed34926f77142b8f00ee4f8544f68067d2dc747da8295d1c456171355b2
    };
    dependencies = with pkgs.python3Packages; [
      httpx
      mcp
    ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postFixup = ''
      wrapProgram "$out/bin/blender-mcp" --set DISABLE_TELEMETRY true
    '';
    pythonImportsCheck = [ "blender_mcp.server" ];
  };

  # The telemetry flip is anchored on the property's own description line: a
  # bare `default=True,` would silently follow whichever property upstream
  # happens to declare first. Double-quoted strings keep the Python indentation
  # byte-exact (an indented Nix string would strip it), and `--replace-fail`
  # turns any upstream rewording into a build error instead of silent telemetry.
  telemetryConsentDescription = "        description=\"Allow collection of prompts, code snippets, screenshots, and trajectory data to help improve MCP for Blender\",\n";
  telemetryDefaultOn = telemetryConsentDescription + "        default=True,";
  telemetryDefaultOff = telemetryConsentDescription + "        default=False,";

  blenderMcpAddon = pkgs.runCommand "blender-mcp-addon-1.9.1-telemetry-off"
    { nativeBuildInputs = [ pkgs.gnused ]; }
    ''
      addon="$out/scripts/addons/blender_mcp.py"
      mkdir -p "$(dirname "$addon")"
      cp ${blenderMcpServer}/${pkgs.python3.sitePackages}/blender_mcp/bundled/addon.py "$addon"
      # Upstream defaults rich telemetry on. Development scenes, screenshots,
      # prompts, and executed code stay local unless the user later opts in.
      substituteInPlace "$addon" \
        --replace-fail ${pkgs.lib.escapeShellArg telemetryDefaultOn} \
          ${pkgs.lib.escapeShellArg telemetryDefaultOff}
    '';

  blenderMcpStartup = pkgs.writeText "blender-mcp-startup.py" ''
    import bpy

    if "blender_mcp" not in bpy.context.preferences.addons:
        bpy.ops.preferences.addon_enable(module="blender_mcp")

    preferences = bpy.context.preferences.addons["blender_mcp"].preferences
    preferences.telemetry_consent = False
    scene = bpy.context.scene
    scene.blendermcp_use_polyhaven = False
    scene.blendermcp_use_hyper3d = False
    scene.blendermcp_use_hunyuan3d = False
    scene.blendermcp_use_sketchfab = False
    scene.blendermcp_use_polypizza = False
  '';

  blenderMcpSession = pkgs.writeShellApplication {
    name = "blender-mcp-session";
    runtimeInputs = [
      pkgs.blender
      pkgs.xvfb
    ];
    text = ''
      export BLENDER_USER_SCRIPTS=${blenderMcpAddon}/scripts
      export DISABLE_TELEMETRY=true
      # The add-on imports `requests` at module scope. Nixpkgs' Blender wrapper
      # already puts `python3Packages.requests` — with its urllib3/idna/certifi
      # closure — on Blender's PYTHONPATH, so injecting a bare requests store
      # path here would only add a dependency-less shadow of the same module.

      # The add-on needs Blender's GUI event loop, even when no monitor is in
      # use. On the workstation's default headless profile, create a private
      # non-TCP X server; an existing graphical session remains untouched.
      if [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        exec blender "$@" --python ${blenderMcpStartup}
      fi

      display_file=$(mktemp)
      xvfb_log=$(mktemp)
      blender_pid=""
      # Both PIDs are declared before the trap: `set -u` would abort cleanup on
      # an unbound name if a signal arrived between arming the trap and the
      # background launch, leaking the X server and the temporary files.
      xvfb_pid=""
      cleanup() {
        [ -z "$blender_pid" ] || kill "$blender_pid" 2>/dev/null || true
        [ -z "$xvfb_pid" ] || kill "$xvfb_pid" 2>/dev/null || true
        rm -f "$display_file" "$xvfb_log"
      }
      trap cleanup EXIT INT TERM

      Xvfb -displayfd 3 -screen 0 1920x1080x24 -nolisten tcp \
        3>"$display_file" >"$xvfb_log" 2>&1 &
      xvfb_pid=$!
      for _ in $(seq 1 100); do
        [ -s "$display_file" ] && break
        kill -0 "$xvfb_pid" 2>/dev/null || {
          cat "$xvfb_log" >&2
          exit 1
        }
        sleep 0.05
      done
      [ -s "$display_file" ] || {
        echo "Xvfb did not publish a display number" >&2
        exit 1
      }

      display_number=$(cat "$display_file")
      export DISPLAY=":$display_number"
      blender "$@" --python ${blenderMcpStartup} &
      blender_pid=$!
      wait "$blender_pid"
    '';
  };
in
{
  environment.systemPackages = [
    pkgs.blender
    blenderMcpServer
    blenderMcpSession
  ];
}
