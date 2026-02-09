{ lib, config, pkgs, ... }:

{
  # Configure sops age key location for home-manager
  sops.age.keyFile = if pkgs.stdenv.isDarwin
    then "${config.home.homeDirectory}/Library/Application Support/sops/age/keys.txt"
    else "${config.home.homeDirectory}/.config/sops/age/keys.txt";

  # Ensure age and sops are available
  home.packages = with pkgs; [ age sops ];
}