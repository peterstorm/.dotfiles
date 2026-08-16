{ pkgs, home-manager, lib, overlays, inputs, ... }:
with builtins;
{

 # extraModules is the per-machine layer on top of the shared roles. Roles are
 # plain home-manager modules, so a machine that wants a role with different
 # settings sets that role's options here rather than forking the role — the
 # module system merges the two. Use it for machine-bound facts only (this box
 # has no Obsidian vault); anything true everywhere belongs in the role.
 mkHMUser = {roles, username, extraModules ? []}:
 let
  mkRole = name: import (../roles/home-manager + "/${name}");
  mod_roles = map (r: mkRole r) roles;
  homeDirectory = if pkgs.stdenv.isDarwin
    then "/Users/${username}"
    else "/home/${username}";
  # Import util libraries to make them available to roles
  util = import ./. { inherit inputs pkgs home-manager lib overlays; };
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
      manual.manpages.enable = false;
      home.stateVersion = "22.11";
      home.username = username;
      home.homeDirectory = homeDirectory;
    }
  ] ++ mod_roles ++ extraModules;
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

