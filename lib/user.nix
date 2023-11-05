{ pkgs, home-manager, lib, system, overlays, ... }:
with builtins;
{

 mkHMUser = {roles, username}:
 let
  mkRole = name: import (../roles/users + "/${name}");
  mod_roles = map (r: mkRole r) roles;
 in home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  modules = [
    {
      nixpkgs.overlays = overlays;
      nixpkgs.config.allowUnfree = true;
      systemd.user.startServices = true;
      home.stateVersion = "22.11";
      home.username = username;
      home.homeDirectory = "/home/${username}";
    }
  ] ++ mod_roles;
  };


 mkSystemUser = {name, groups, uid, ...}:
 {
    users.users."${name}" = {
      name = name;
      isNormalUser = true;
      isSystemUser = false;
      extraGroups = groups;
      uid = uid;
      initialPassword = "hunter2";
    };
  };
}

