{pkgs, config, lib, ...}:
{
  home.packages = with pkgs; [
    (lutris.override {
      extraPkgs = pkgs: [
        wineWowPackages.stable
        winetricks
      ];
    })
  ];
}
