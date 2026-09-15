{pkgs, config, lib, ...}:
{
  imports = [
    ../shared/xmobar
  ];

  home.keyboard = null;

  # Binaries the multimedia key bindings in xmonad.hs spawn. The role owns the
  # WM experience, so it installs the tools those bindings depend on, keeping
  # the bindings self-contained on every machine that loads this role:
  #   - pamixer: volume/mute via the Pulse API (this stack is PipeWire with
  #     pipewire-pulse; amixer would hit the kernel ALSA mixer — wrong layer)
  #   - brightnessctl: backlight via the systemd-logind API — no udev rules or
  #     setuid wrapper needed (programs.light was removed from nixpkgs)
  #   - playerctl: MPRIS media keys (controls firefox/spotify/mpv — whatever
  #     is playing, not one hardcoded player)
  home.packages = with pkgs; [ pamixer brightnessctl playerctl ];

  xsession = {
    enable = true;
    windowManager.xmonad = {
      enableContribAndExtras = true;
      extraPackages = hp: [
        hp.xmonad-contrib
        hp.xmonad-extras
        hp.xmonad
      ];
      config = ./xmonad.hs;
    };
  };
  home.file = {
    ".xmonad/xmonad.hs".source = ./xmonad.hs;
  };

  # xmonad.hs launches two Firefox profiles by name: `firefox -P noscratchpad`
  # (the normal browser) and `firefox -P scratchpad --class foxpad` (the overlay
  # scratchpad). Firefox's `-P <name>` does NOT create a missing profile — it
  # just opens an empty Profile Manager — so on a fresh ~/.mozilla those bindings
  # land on nothing. This ensures both profiles exist, creating ONLY what is
  # missing and never touching existing profiles or their data (bookmarks,
  # logins), so it is safe on machines that already have them.
  home.activation.firefoxScratchpadProfiles =
    lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      export PATH="${lib.makeBinPath [ pkgs.coreutils pkgs.gnugrep ]}:$PATH"
      ffDir="$HOME/.mozilla/firefox"
      ini="$ffDir/profiles.ini"
      ensureProfile() {
        name="$1"
        $DRY_RUN_CMD mkdir -p "$ffDir/$name"
        if [ -f "$ini" ] && grep -qx "Name=$name" "$ini"; then
          return
        fi
        if [ ! -f "$ini" ]; then
          $DRY_RUN_CMD tee "$ini" >/dev/null <<EOF
[General]
StartWithLastProfile=1
Version=2
EOF
          next=0
        else
          last=$(grep -oE '^\[Profile[0-9]+\]' "$ini" | grep -oE '[0-9]+' | sort -n | tail -1)
          if [ -z "$last" ]; then next=0; else next=$((last + 1)); fi
        fi
        $DRY_RUN_CMD tee -a "$ini" >/dev/null <<EOF

[Profile$next]
Name=$name
IsRelative=1
Path=$name
EOF
      }
      ensureProfile noscratchpad
      ensureProfile scratchpad
    '';
}
