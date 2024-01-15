{ inputs, pkgs, home-manager, system, lib, overlays, ...}:
rec {
  user = import ./user.nix { inherit pkgs home-manager lib system overlays; };
  host = import ./host.nix { inherit inputs system pkgs home-manager lib user; };
  shell = import ./shell.nix { inherit pkgs; };
}
