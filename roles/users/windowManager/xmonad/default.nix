{pkgs, config, lib, ...}:
let
  extra = ''
    ${pkgs.xcape}/bin/xcape -e "Hyper_L=Caps_Lock;Hyper_R=backslash"
  '';
in {

  imports = [
    #../shared/fonts.nix
    ../shared/xmobar
    ../shared/alacritty
    ../shared/applications.nix
  ];

  home.packages = with pkgs; [
    xcape
  ];

  xsession = {
    enable = true;
    initExtra = extra;
    windowManager.xmonad = {
      enableContribAndExtras = true;
      extraPackages = hp: [
        hp.xmonad-contrib
        hp.xmonad-extras
        hp.xmonad
      ];
      config = ./xmonad.hs;
    };
  };
}
