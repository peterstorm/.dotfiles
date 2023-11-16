{
  description = "nixos config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    neovim-nightly-overlay.url = "github:nix-community/neovim-nightly-overlay";
    neovim-nightly-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs @ { self, nixpkgs, home-manager, ... }:
  let

    inherit (nixpkgs) lib;
    util = import ./lib { 
      inherit system pkgs home-manager lib; overlays = (pkgs.overlays);
    };

    inherit (util) host;
    inherit (util) user;
    inherit (util) shell;

    system = "x86_64-linux";

    pkgs = import nixpkgs {
      inherit system;
      config = { allowUnfree = true; };
      overlays = [
        inputs.neovim-nightly-overlay.overlay 
      ];
    };

  in {

    homeManagerConfigurations = {

      peterstorm = user.mkHMUser {
        roles = [ "core-apps" "window-manager/xmonad" "dunst" "games" ];
        username = "peterstorm";
      };

      homelab = user.mkHMUser {
        roles = [ "core-apps" ];
        username = "peterstorm";
      };
    };

    nixosConfigurations = {

      laptop-xps = host.mkHost {
        name = "laptop-xps";
        roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "laptop-nvidia-graphics" ];
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
        laptop = true;
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
        laptop = true;
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
        laptop = true;
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
        users = [{
          name = "peterstorm";
          groups = [ "wheel" "networkmanager" "docker" ];
          uid = 1000;
          ssh_keys = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ+2TgMEWwmsE5i/kEHHo7iJyD4BzItKMakGg2AcbgyH peterstorm" ];
        }];
        cpuCores = 8;
        laptop = true;
      };

    };
  };
}
