{ pkgs, ... }:

let
  # Blender MCP has two processes by design: Blender's reviewed add-on owns a
  # loopback-only socket inside the GUI, while this stdio server is launched by
  # Pi through `ssh desktop`. Pin the published wheel rather than mutable PyPI
  # metadata; the wheel also contains the exact add-on paired with its protocol.
  blenderMcpServer = pkgs.python3Packages.buildPythonApplication {
    pname = "blender-mcp";
    version = "1.9.0";
    format = "wheel";
    src = pkgs.fetchurl {
      url = "https://files.pythonhosted.org/packages/c3/f1/e2c1055f6c409723daae21cd1c8027b71bfb9887e1cc54147e3e409c5f59/blender_mcp-1.9.0-py3-none-any.whl";
      hash = "sha256-8HWSkbV0jDX82r1o+JtoTPqubGHdR1+H1ZHd3O9j+fo="; # f0759291b5748c35fcdabd68f89b684cfaae6c61dd475f87d591dddcef63f9fa
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

  blenderMcpAddon = pkgs.runCommand "blender-mcp-addon-1.9.0-telemetry-off"
    { nativeBuildInputs = [ pkgs.gnused ]; }
    ''
      addon="$out/scripts/addons/blender_mcp.py"
      mkdir -p "$(dirname "$addon")"
      cp ${blenderMcpServer}/${pkgs.python3.sitePackages}/blender_mcp/bundled/addon.py "$addon"
      # Upstream defaults rich telemetry on. Development scenes, screenshots,
      # prompts, and executed code stay local unless the user later opts in.
      substituteInPlace "$addon" \
        --replace-fail 'default=True,' 'default=False,'
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
      export PYTHONPATH=${pkgs.python3Packages.requests}/${pkgs.python3.sitePackages}''${PYTHONPATH:+:$PYTHONPATH}
      export DISABLE_TELEMETRY=true

      # The add-on needs Blender's GUI event loop, even when no monitor is in
      # use. On the workstation's default headless profile, create a private
      # non-TCP X server; an existing graphical session remains untouched.
      if [ -n "''${DISPLAY:-}" ] || [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        exec blender "$@" --python ${blenderMcpStartup}
      fi

      display_file=$(mktemp)
      xvfb_log=$(mktemp)
      blender_pid=""
      cleanup() {
        [ -z "$blender_pid" ] || kill "$blender_pid" 2>/dev/null || true
        kill "$xvfb_pid" 2>/dev/null || true
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
