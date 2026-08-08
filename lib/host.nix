{ inputs, system, pkgs, home-manager, lib, user, ...}:
with builtins;
{

  # Installer ISO for a target host. `target` is null for the thin image, or
  # `{ toplevel; diskoScript; }` from a nixosConfiguration to bake that whole
  # system into the stick for an offline install. See machines/installer.
  mkInstaller = { name ? "installer", target ? null }:
    lib.nixosSystem {
      inherit system;

      specialArgs = { inherit inputs target; };

      modules = [
        ../machines/installer
        {
          networking.hostName = "${name}";
          nixpkgs.pkgs = pkgs;
        }
      ];
    };

    mkHost = {
      name,
      NICs,
      initrdAvailableMods,
      initrdMods,
      kernelMods,
      kernelPatches,
      kernelParams,
      kernelPackage,
      roles,
      machine,
      cpuCores,
      users,
      wifi ? [],
      gpuTempSensor ? null,
      cpuTempSensor ? null}:
    let
      # Import util to make it available to NixOS roles
      util = import ./. { inherit inputs pkgs home-manager lib; overlays = []; };
      networkCfg = listToAttrs (map (n: {
        name = "${n}"; value = { useDHCP = true; };
      }) NICs);

      userCfg = {
        inherit name NICs roles cpuCores gpuTempSensor cpuTempSensor;
      };

      sysdata = [{
      }];

      roles_mods = (map (r: mkRole r) roles );
      machine_mods = (map (m: mkMachine m) machine );
      sys_users = (map (u: user.mkSystemUser u) users);

      flaten = lst: foldl' (l: r: l // r) {} lst;

      mkRole = name: import (../roles + "/${name}");

      mkMachine = name: import (../machines + "/${name}");

    in lib.nixosSystem {
      inherit system;

      specialArgs = {
        inherit inputs util;
      };

      modules = [
        {
          imports = [ ../modules ] ++ roles_mods ++ sys_users ++ machine_mods;

          environment.etc = {
            "hmsystemdata.json".text = builtins.toJSON userCfg;
          };

          networking.hostName = "${name}";
          networking.interfaces = networkCfg;
          networking.wireless.interfaces = wifi;

          networking.networkmanager.enable = true;
          networking.useDHCP = false; # Disable any new interface added that is not in config.

          boot.initrd.availableKernelModules = initrdAvailableMods;
          boot.initrd.kernelModules = initrdMods;
          boot.kernelModules = kernelMods;
          boot.kernelPatches = kernelPatches;
          boot.kernelParams = kernelParams;
          boot.kernelPackages = kernelPackage;

          nixpkgs.pkgs = pkgs;
          nix.settings.max-jobs = lib.mkDefault cpuCores;

          system.stateVersion = "22.11";

        }

      ];
    };


}

