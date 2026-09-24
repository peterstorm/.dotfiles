# Gaming on desktop (graphical specialisation)

`desktop` boots headless for inference by default. Gaming is enabled **only** in
its graphical specialisation, not on `homelab`, the laptops, or the base desktop
profile. To apply the config and enter the gaming profile now:

```sh
cd ~/.dotfiles
./system-apply.sh --specialisation graphical
```

Alternatively choose **NixOS (graphical)** at boot after rebuilding. Merely
running `systemctl isolate graphical.target` on the headless profile starts the
display manager, but does **not** activate the gaming packages or VM map limit.
Switching back to `multi-user.target` closes the graphical session; stop games
first. Don't run inference workloads on the same GPUs while playing.

## Steam games

Open `steam` from the XMonad session and sign in. In Steam **Settings →
Compatibility**, enable Steam Play for all titles if needed; Valve Proton is
installed and updated by Steam. GE-Proton is also provided as a pinned Steam
compatibility tool by NixOS; select it per game in **Properties → Compatibility**
when the Valve runner doesn't work. `protontricks` is available for prefix
fixes. `gamemoderun %command%` and `mangohud %command%` are optional Steam
launch options for performance mode and an overlay. `vulkaninfo --summary`
checks Vulkan. Steam's controller rules and 32-bit graphics/audio support
come from `programs.steam.enable`, not just installing the Steam executable.
No Remote Play/server firewall ports are opened.

## Star Citizen

`lug-helper` (LUG Helper) is the Star Citizen Linux Users Group's installer
and maintenance tool, packaged by nixpkgs. Launch it **as your normal user**
from the graphical session and run its **Preflight Check**. For an RSI Launcher
install on NixOS, start with `lutris` and its [Star Citizen installer](https://lutris.net/games/star-citizen/): Lutris
runs downloaded Wine runners inside an FHS environment and includes Wine and
Winetricks here. You can also use LUG Helper's **Install Star Citizen Launcher**
path, but its standalone downloaded Wine runner may not start directly on NixOS;
if so, use Lutris or the NixOS-specific [nix-citizen RSI launcher](https://github.com/LovingMelody/nix-citizen)
instead. Follow the LUG wiki for current runner and launcher settings. This is
separate from Steam: **GE-Proton for Steam is not the Wine runner for this
install**.

The graphical profile sets `vm.max_map_count = 16777216` for LUG's preflight.
If its file-descriptor check fails, verify `ulimit -Hn` (LUG asks for at least
524288) and fix the host's login limit declaratively instead of accepting a
one-off system tweak. LUG's [wiki](https://wiki.starcitizen-lug.org/) tracks
current runner/launcher requirements and troubleshooting. Game compatibility
and anti-cheat policy can change with updates; this config prepares the host,
but cannot guarantee that Star Citizen will launch or allow online play.
