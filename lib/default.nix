{ inputs, pkgs, home-manager, system ? null, lib, overlays, ...}:
rec {
  user = import ./user.nix { inherit inputs pkgs home-manager lib overlays; };
  host = import ./host.nix { inherit inputs system pkgs home-manager lib user; };
  shell = import ./shell.nix { inherit pkgs; };
  sops = import ./sops.nix { inherit lib; };
}
