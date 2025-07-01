{ lib, config, pkgs, ... }:

{
  # Configure sops age key location for home-manager
  sops.age.keyFile = if pkgs.stdenv.isDarwin 
    then "${config.home.homeDirectory}/Library/Application Support/sops/age/keys.txt"
    else "/var/lib/sops-nix/keys.txt";
    
  # Ensure age and sops are available
  home.packages = with pkgs; [ age sops ];
}