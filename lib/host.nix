{ inputs, system, pkgs, home-manager, lib, user, overlays, ...}:
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
      hmUsers ? [],
      wifi ? [],
      gpuTempSensor ? null,
      cpuTempSensor ? null}:
    let
      # Import util to make it available to NixOS roles. Overlays are the
      # real ones (not []), so home-manager users integrated via hmUsers get
      # the same package set as the standalone homeManagerConfigurations.
      util = import ./. { inherit inputs pkgs home-manager lib overlays; };
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

      # home-manager integrated into the system build: one atomic
      # `nixos-rebuild switch` applies the system and the user's home config
      # together. No separate hm-apply step, no window in which the two
      # layers can disagree (that gap is how the laptops ran stock XMonad).
      hm_users = lib.listToAttrs (map (u: {
        name = u.username;
        # home-manager.users.<name> is a single module; compose the list of
        # role modules through `imports` (the documented shape).
        value = { imports = util.user.mkHMUserModules u; };
      }) hmUsers);

      flaten = lst: foldl' (l: r: l // r) {} lst;

      mkRole = name: import (../roles + "/${name}");

      mkMachine = name: import (../machines + "/${name}");

    in lib.nixosSystem {
      inherit system;

      specialArgs = {
        inherit inputs util;
      };

      modules = [
        # Imported unconditionally: every mkHost machine is a real host with
        # home-manager users. The installer ISO does not go through mkHost
        # (it uses mkInstaller), so nothing HM-related is baked into it.
        inputs.home-manager.nixosModules.home-manager
        {
          imports = [ ../modules ] ++ roles_mods ++ sys_users ++ machine_mods;

          home-manager = {
            users = hm_users;
            # The roles expect the repo's `util` (and `inputs`) as module
            # arguments — the same extraSpecialArgs mkHMUser provides in the
            # standalone builder. Without them the module system falls back to
            # querying `_module.args`, which forces `config` mid-evaluation:
            # infinite recursion.
            extraSpecialArgs = { inherit inputs util; };
          };

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

