{
  description = "nixos config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-claude-pr.url = "github:nixos/nixpkgs/pull/447265/head";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    nix-vscode-extensions.url = "github:nix-community/nix-vscode-extensions";
    nix-vscode-extensions.inputs.nixpkgs.follows = "nixpkgs";
    llm-agents.url = "github:numtide/llm-agents.nix";
    loom-tui.url = "github:peterstorm/loom-tui";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
    # MediaTek MT7927 / MT6639 (Filogic 380) WiFi 7 + Bluetooth. The ProArt
    # X870E-CREATOR ships either this or a Qualcomm QCNCM865; the MT7927 is not
    # in mainline, so it needs out-of-tree mt76 modules plus firmware extracted
    # from ASUS's Windows driver. This flake does both against whatever kernel
    # the host runs. See machines/desktop/default.nix.
    mt7927.url = "github:cmspam/mt7927-nixos";
    mt7927.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ { self, nixpkgs, home-manager, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem = { self', system, pkgs, lib, config, inputs', ... }: let

        overlays = [
          (import ./overlays/vscode-insiders.nix)
          (import ./overlays/antigravity.nix)
          (import ./overlays/pi-coding-agent.nix)
          inputs.nix-vscode-extensions.overlays.default
        ];

        pkgs = import self.inputs.nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
        };

        inherit (nixpkgs) lib;
        util = import ./lib {
          inherit inputs pkgs home-manager system lib overlays;
        };
        inherit (util) host user shell;

      in {

        legacyPackages.homeManagerConfigurations = {

          # Standalone home-manager outputs are for NON-NixOS hosts only (the
          # work Mac). NixOS hosts integrate their home-manager config into the
          # system build via home-manager.users (see the hmUsers field on each
          # host below), so `nixos-rebuild switch` applies system and home
          # atomically — no separate hm-apply step, no window where the two
          # layers can disagree.

          # Work Mac. Picks core-apps roles individually rather than importing the
          # whole set, so the Linux-only members (window manager, dunst) and the
          # git role's personal user.name/user.email stay off this box.
          hansen142 = user.mkHMUser {
            roles = [
              "core-apps/neovim"
              "core-apps/darwin"
              "core-apps/tmux"
              "core-apps/nix-direnv-zsh"
              "core-apps/starship"
              "core-apps/alacritty"
              "core-apps/pi"
              "core-apps/claude"
            ];
            username = "hansen142";
            # The claude role in full assumes the homelab/desktop workspace. This
            # box has neither the Obsidian vault the obsidian plugin reads nor any
            # reclaw work, and cloning a repo whose backing state is absent buys a
            # plugin that can only fail at runtime. Narrowed here rather than in
            # the role: the other machines still want both.
            extraModules = [{
              dotfiles.claude.plugins = [ "loom" "cortex" "feynman" ];
              dotfiles.claude.extraWorkspaceRepos = [ ];
            }];
          };
        };

        legacyPackages.nixosConfigurations = {

          laptop-xps = host.mkHost {
            name = "laptop-xps";
            roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "laptop-nvidia-graphics" "warp" ];
            hmUsers = [
              # core-apps restores the user config the August HM decoupling
              # stranded (nvim, tmux, ...); the window-manager role owns
              # ~/.xmonad/xmonad.hs + xmobar. No homelab-sync roles: this box
              # runs none of those services.
              { username = "peterstorm"; roles = [ "core-apps" "window-manager/xmonad" "dunst" ]; }
            ];
            machine = [ "laptop-xps" ];
            NICs = [ "wlp0s20f3" ];
            kernelPackage = pkgs.linuxPackages_latest;
            initrdAvailableMods = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
            initrdMods = [ "dm-snapshot" ];
            kernelMods = [ "kvm-intel" "nvidia" "nvidia_modeset" "nvidia_drm" "nvidia_uvm" ];
            kernelPatches = [];
            kernelParams = [ "acpi_rev_override" ];
            users = [{
              name = "peterstorm";
              groups = [ "wheel" "networkmanager" "docker" "video" ];
              uid = 1000;
              ssh_keys = [];
            }];
            cpuCores = 8;
          };

          laptop-work = host.mkHost {
            name = "laptop-work";
            roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "warp" ];
            hmUsers = [
              { username = "peterstorm"; roles = [ "core-apps" "window-manager/xmonad" "dunst" ]; }
            ];
            machine = [ "laptop-work" ];
            NICs = [ "wlp0s20f3" ];
            kernelPackage = pkgs.linuxPackages_latest;
            initrdAvailableMods = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
            initrdMods = [ "dm-snapshot" ];
            kernelMods = [ "kvm-intel" ];
            kernelPatches = [];
            kernelParams = [ "acpi_rev_override" ];
            users = [{
              name = "peterstorm";
              groups = [ "wheel" "networkmanager" "docker" "video" ];
              uid = 1000;
              ssh_keys = [];
            }];
            cpuCores = 8;
          };

          desktop = host.mkHost {
            name = "desktop";
            roles = [ "core" "ssh" "wifi" "efi" "bluetooth" "dual-desktop-plasma" "nvidia-graphics" ];
            hmUsers = [
              # No sops-homelab: the Gemini key it carried is no longer needed
              # (cortex embeds locally). No homelab-sync roles either: the
              # obsidian/vdirsyncer/sonarr services run on the homelab box.
              { username = "peterstorm"; roles = [ "core-apps" "window-manager/xmonad" "dunst" "desktop-audio" ]; }
            ];
            machine = [ "desktop" ];
            NICs = [ "wlp5s0" "enp6s0" ];
            initrdAvailableMods = [ "xhci_pci" "nvme" "ahci" "sd_mod" "usbhid" ];
            initrdMods = [];
            kernelMods = [ "kvm-amd" ];
            kernelPatches = [];
            kernelParams = [];
            kernelPackage = pkgs.linuxPackages;
            users = [{
              name = "peterstorm";
              groups = [ "wheel" "networkmanager" "docker" "video" "render" ];
              uid = 1000;
              ssh_keys = builtins.readFile ./authorized_keys.txt;
            }];
            cpuCores = 16;
          };

          homelab = host.mkHost {
            name = "homelab";
            roles = [ "core" "wifi" "efi" "bluetooth" "ssh" "k3s" "cloudflared" "reclaw" ];
            hmUsers = [
              # HEADLESS: no X11/seat on this box (dunst's 201 boot failures
              # over 2 weeks are the proof), so no window-manager/dunst roles
              # — those stay on the display machines only.
              { username = "peterstorm"; roles = [ "core-apps" "obsidian-git-sync" "obsidian-headless-sync" "vdirsyncer" "sonarr-missing-search" ]; }
              { username = "homelab"; roles = [ "core-apps" ]; }
            ];
            machine = [ "homelab" ];
            NICs = [ "wlp3s0" ];
            initrdAvailableMods = [ "xhci_pci" "nvme" "ahci" "sd_mod" "usbhid" ];
            initrdMods = [];
            kernelMods = [ "kvm-amd" ];
            kernelPatches = [];
            kernelParams = [];
            kernelPackage = pkgs.linuxPackages_latest;
            users = [
              {
                name = "homelab";
                groups = [ "wheel" "networkmanager" "docker" ];
                uid = 1001;
                ssh_keys = builtins.readFile ./authorized_keys.txt;
              }
              {
                name = "peterstorm";
                groups = [ "wheel" "networkmanager" "docker" ];
                uid = 1000;
                ssh_keys = builtins.readFile ./authorized_keys.txt;
              }
            ];
            cpuCores = 8;
          };

        };

        # Installer sticks for the `desktop` workstation. See machines/installer.
        #
        #   nix build .#installer-iso          # ~1 GB, needs the laptop to install
        #   nix build .#installer-iso-offline  # carries the whole desktop closure
        #
        # Both boot with sshd up, your keys installed, ZFS in the kernel, and mDNS
        # publishing `installer.local`, so the box never needs a monitor.
        packages = lib.optionalAttrs (system == "x86_64-linux") {
          installer-iso = (host.mkInstaller { }).config.system.build.isoImage;

          installer-iso-offline =
            (host.mkInstaller {
              target = {
                inherit (config.legacyPackages.nixosConfigurations.desktop.config.system.build)
                  toplevel
                  diskoScript
                  ;
              };
            }).config.system.build.isoImage;
        };

      };

      flake = {
        nixosConfigurations = self.legacyPackages.x86_64-linux.nixosConfigurations;
        homeConfigurations = self.legacyPackages.x86_64-linux.homeManagerConfigurations;
      };

    };
}
