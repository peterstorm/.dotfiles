{pkgs, config, lib, ...}:
{
  home.packages = with pkgs; [
    nerdfonts
    fira-code
    fira-code-symbols
    ubuntu_font_family
  ];

  fonts.enableDefaultFonts = true;
  fonts.fontconfig = {
    defaultFonts = {
      serif = [ "Ubuntu" ];
      sansSerif = [ "Ubuntu" ];
      monospace = [ "Ubuntu" ];
    };
  };


}

