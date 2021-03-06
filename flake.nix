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
      overlays = [ inputs.neovim-nightly-overlay.overlay ];
    };

  in {

    homeManagerConfigurations = {

      peterstorm = user.mkHMUser {
        roles = [ "core-apps" "window-manager/xmonad" "dunst" ];
        username = "peterstorm";
      };
    };

    nixosConfigurations = {

      laptop-xps = host.mkHost {
        name = "laptop-xps";
        roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "laptop" "plex" ];
        machine = [ "laptop-xps" ];
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
        kernelPatches = [{
          name = "enable-soundwire-drivers";
          patch = null;
          extraConfig = ''
            SND_SOC_INTEL_USER_FRIENDLY_LONG_NAMES y
            SND_SOC_INTEL_SOUNDWIRE_SOF_MACH m
            SND_SOC_RT1308 m
          '';
          ignoreConfigErrors = true;
        }];
        kernelParams = [ "acpi_rev_override" ];
        users = [{
          name = "peterstorm";
          groups = [ "wheel" "networkmanager" "docker" ];
          uid = 1000;
        }];
        cpuCores = 8;
        laptop = true;
      };

      desktop = host.mkHost {
        name = "desktop";
        roles = [ "core" "wifi" "efi" "bluetooth" "desktop-plasma" "nvidia-graphics" ];
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
        }];
        cpuCores = 8;
        laptop = true;
      };

    };
  };
}
