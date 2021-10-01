{pkgs, config, lib, ...}:
{
  home.packages = with pkgs; [
    nerdfonts
    ubuntu_font_family
  ];

  home.fonts.enableDefaultFonts = true;
  home.fonts.fontconfig = {
    defaultFonts = {
      serif = [ "Ubuntu" ];
      sansSerif = [ "Ubuntu" ];
      monospace = [ "Ubuntu" ];
    };
  };


}

