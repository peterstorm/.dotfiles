{pkgs, lib, config, ...}:
{

  programs.xmobar = {
    enable = true;
    extraConfig = ''
      -- http://projects.haskell.org/xmobar/
      -- install xmobar with these flags: --flags="with_alsa" --flags="with_mpd" --flags="with_xft"  OR --flags="all_extensions"
      -- you can find weather location codes here: http://weather.noaa.gov/index.html

      Config { font    = "xft:Ubuntu:weight=bold:pixelsize=11:antialias=true:hinting=true"
             , additionalFonts = [ "xft:Nono Sans:pixelsize=11:antialias=true:hinting=true"
                                 , "xft:Nono Sans:pixelsize=16:antialias=true:hinting=true"
                                 ]
             , bgColor = "#292d3e"
             , fgColor = "#f07178"
             , position = TopSize L 100 24
             , lowerOnStart = True
             , hideOnStart = False
             , allDesktops = True
             , persistent = True
             , iconRoot = "/home/peterstorm/.dotfiles/roles/users/windowManager/shared/xmobar/xpm/"  -- default: "."
             , commands = [ 
                            -- Time and date
                            Run Date "%b %d %Y (%H:%M)" "date" 50
                            -- Cpu usage in percent
                          , Run Cpu ["-t", "cpu: (<total>%)","-H","50","--high","red"] 20
                            -- Ram used number and percent
                          , Run Memory ["-t", "mem: <used>M (<usedratio>%)"] 20
                            -- Disk space free
                          , Run DiskU [("/", "hdd: <free> free")] [] 60
                            -- Runs a standard shell command 'uname -r' to get kernel version
                          , Run Battery ["BAT0"] 10
                            -- Runs battery status
                          , Run Com "uname" ["-r"] "" 3600
                            -- Prints out the left side items such as workspaces, layout, etc.
                            -- The workspaces are 'clickable' in my configs.
                          , Run UnsafeStdinReader
                          ]
             , sepChar = "%"
             , alignSep = "}{"
             , template = "<action=`xdotool key control+alt+g`><icon=haskell_20.xpm/> </action><fc=#666666>  |</fc> %UnsafeStdinReader% }{ <fc=#666666><fn=2>|</fn></fc><fc=#b3afc2><fn=1></fn>  %uname% </fc><fc=#666666> <fn=2>|</fn></fc><fc=#FFB86C> %cpu% </fc><fc=#666666><fn=2>|</fn></fc> <fc=#FF5555> %memory% </fc><fc=#666666> <fn=2>|</fn></fc> <fc=#82AAFF> %battery% </fc><fc=#666666><fn=2>|</fn></fc><fc=#8BE9FD> %date%  </fc>" 
             }
    '';
  };
}

