{ inputs, system, pkgs, home-manager, lib, user, ...}:
with builtins;
{

  mkISO = { name, initrdMods, kernelMods, kernelParams, kernelPackage, roles }:
    let
      roles_mods = (map (r: mkRole r) roles );

      mkRole = name: import (../roles/iso + "/${name}");

    in lib.nixosSystem {
      inherit system;

      specialArgs = {};

      modules = [
        {
          imports = [ ../modules ] ++ roles_mods;

          networking.hostName = "${name}";
          networking.useDHCP = false;

          boot.initrd.availableKernelModules = initrdMods;
          boot.kernelModules = kernelMods;

          boot.kernelParams = kernelParams;
          boot.kernelPackages = kernelPackage;

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
      util = import ./. { inherit inputs pkgs home-manager system lib; overlays = []; };
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

