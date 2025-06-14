{ lib, config, pkgs, ... }:

{
  # Configure sops age key location for home-manager
  # Note: This assumes the user has read access to the system-wide key
  # Alternatively, could use ~/.config/sops/age/keys.txt for user-specific keys
  sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
}