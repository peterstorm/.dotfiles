{pkgs, config, lib, ...}:
{
  imports = [
    ../shared/xmobar
  ];

  xsession = {
    enable = true;
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
  home.file = {
    ".xmonad/xmonad.hs".source = ./xmonad.hs;
  };
}
