{
  description = "nixos config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {nixpkgs, home-manager, ... }:
  let

    inherit (nixpkgs) lib;
    util = import ./lib { 
      inherit system pkgs home-manager lib; overlays = (pkgs.overlays);
    };

    inherit (util) host;
    inherit (util) user;

    system = "x86_64-linux";

    pkgs = import nixpkgs {
      inherit system;
      config = { allowUnfree = true; };
    };

  in {

    homeManagerConfigurations = {
      peterstorm = user.mkHMUser {
        roles = [ "git" "windowManager/xmonad" "tmux" ];
        username = "peterstorm";
      };
    };

    nixosConfigurations = {
      laptop-xps = host.mkHost {
        name = "laptop-xps";
        NICs = [ "wlp0s20f3" ];
        kernelPackage = pkgs.linuxPackages_latest;
        initrdMods = [ "xhci_pci" "nvme" "usb_storage" "sd_mod" "rtsx_pci_sdmmc" ];
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
        roles = [ "core" "wifi" "efi" "intel-graphics" "bluetooth" "desktop-plasma" ];
        users = [{
          name = "peterstorm";
          groups = [ "wheel" "networkmanager" "docker" ];
          uid = 1000;
        }];
        cpuCores = 8;
        laptop = true;
        services = {
          xserver.libinput.enable = true;
          thermald.enable = true;
        };
      };
    };
  };
}
