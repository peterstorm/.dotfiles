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
  };

  outputs = inputs @ { self, nixpkgs, home-manager, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {

      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      perSystem = { self', system, pkgs, lib, config, inputs', ... }: let

        pkgs = import self.inputs.nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        inherit (nixpkgs) lib;
        util = import ./lib {
          inherit inputs pkgs home-manager system lib; overlays = [];
        };
        inherit (util) host user shell;

      in {

        legacyPackages.homeManagerConfigurations = {

          peterstorm = user.mkHMUser {
            roles = [ "core-apps" "window-manager/xmonad" "dunst" "games" "sops-template-example" ];
            username = "peterstorm";
          };

          hansen142 = user.mkHMUser {
            roles = [
              "core-apps/neovim"
              "core-apps/darwin"
              "core-apps/tmux"
              "core-apps/nix-direnv-zsh"
              "core-apps/starship"
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
            roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "laptop-nvidia-graphics" "sops-template-nixos-example" ];
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
              groups = [ "wheel" "networkmanager" "docker" ];
              uid = 1000;
              ssh_keys = [];
            }];
            cpuCores = 8;
          };

          laptop-work = host.mkHost {
            name = "laptop-work";
            roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" ];
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
              groups = [ "wheel" "networkmanager" "docker" ];
              uid = 1000;
              ssh_keys = [];
            }];
            cpuCores = 8;
          };

          desktop = host.mkHost {
            name = "desktop";
            roles = [ "core" "wifi" "efi" "bluetooth" "dual-desktop-plasma" "nvidia-graphics" ];
            machine = [ "desktop" ];
            NICs = [ "wlp5s0" "enp6s0" ];
            initrdAvailableMods = [ "xhci_pci" "nvme" "ahci" "sd_mod" "usbhid" ];
            initrdMods = [];
            kernelMods = [ "kvm-amd" ];
            kernelPatches = [];
            kernelParams = [];
            kernelPackage = pkgs.linuxPackages_latest;
            users = [{
              name = "peterstorm";
              groups = [ "wheel" "networkmanager" "docker" ];
              uid = 1000;
              ssh_keys = [];
            }];
            cpuCores = 8;
          };

          homelab = host.mkHost {
            name = "homelab";
            roles = [ "core" "wifi" "efi" "bluetooth" "ssh" "k3s" "cloudflared" ];
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

      };

    };
}
