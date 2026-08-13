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

          # Homelab server: headless (no X11/seat ever — dunst's 201 boot failures
          # over 2 weeks are the proof), so xmonad/dunst are vestigial here. The
          # desktop profile below keeps them for the real display machine.
          peterstorm = user.mkHMUser {
            roles = [ "core-apps" "sops-homelab" "obsidian-git-sync" "obsidian-headless-sync" "vdirsyncer" "sonarr-missing-search" ];
            username = "peterstorm";
          };

          # Desktop workstation: same user, but a subset of roles. The obsidian/
          # vdirsyncer/sonarr homelab roles are omitted (they want services this
          # box doesn't run), but sops-homelab IS included so cortex gets its
          # GEMINI_API_KEY for embeddings — that needs the age key seeded at
          # ~/.config/sops/age/keys.txt. Apply with `./hm-apply.sh desktop`.
          desktop = user.mkHMUser {
            roles = [ "core-apps" "window-manager/xmonad" "dunst" "sops-homelab" "desktop-audio" ];
            username = "peterstorm";
          };

          hansen142 = user.mkHMUser {
            roles = [
              "core-apps/neovim"
              "core-apps/darwin"
              "core-apps/tmux"
              "core-apps/nix-direnv-zsh"
              "core-apps/starship"
              "core-apps/alacritty"
              "core-apps/pi"
            ];
            username = "hansen142";
          };

          homelab = user.mkHMUser {
            roles = [ "core-apps" ];
            username = "homelab";
          };
        };

        legacyPackages.nixosConfigurations = {

          laptop-xps = host.mkHost {
            name = "laptop-xps";
            roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "laptop-nvidia-graphics" "warp" ];
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
