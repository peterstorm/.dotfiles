{ pkgs, home-manager, lib, system, overlays, inputs, ... }:
with builtins;
{

 mkHMUser = {roles, username}:
 let
  mkRole = name: import (../roles/home-manager + "/${name}");
  mod_roles = map (r: mkRole r) roles;
  homeDirectory = if system == "aarch64-darwin" 
    then "/Users/${username}" 
    else "/home/${username}";
  # Import util libraries to make them available to roles
  util = import ./. { inherit inputs pkgs home-manager system lib overlays; };
 in home-manager.lib.homeManagerConfiguration {
  inherit pkgs;
  extraSpecialArgs = { inherit inputs util; };
  modules = [
    inputs.sops-nix.homeManagerModules.sops
    (import ../roles/home-manager/sops-config)
    {
      nixpkgs.overlays = overlays;
      nixpkgs.config.allowUnfree = true;
      systemd.user.startServices = true;
      home.stateVersion = "22.11";
      home.username = username;
      home.homeDirectory = homeDirectory;
    }
  ] ++ mod_roles;
  };


 mkSystemUser = {name, groups, uid, ssh_keys, ...}:
 {
    users.users."${name}" = {
      name = name;
      isNormalUser = true;
      isSystemUser = false;
      extraGroups = groups;
      uid = uid;
      initialPassword = "hunter2";
      openssh.authorizedKeys.keys = lib.splitString "\n" ssh_keys;
    };
  };
}

