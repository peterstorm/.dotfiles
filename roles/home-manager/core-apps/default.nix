{pkgs, config, lib, inputs, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  programs.ssh = {
    enable = true;
    matchBlocks = {
      homelab = {
        hostname = "192.168.0.28";
        user = "peterstorm";
      };
    };
  };

  imports = [
    ./git
    ./tmux
    ./alacritty
    ./starship
    ./neovim
    ./nix-direnv
  ];

  programs.bash = {
    enable = true;
    initExtra = ''
      if [ -z "$SSH_AUTH_SOCK" ] ; then
        eval `ssh-agent -s`
        ssh-add
      fi
    '';
    shellAliases = {
      lock = "i3lock -c 000000";
      sus = "systemctl suspend";
      warpc = "warp-cli connect";
      warpd = "warp-cli disconnect";
      claude = "claude --plugin-dir ~/.claude/plugins/obsidian";
    };
  };

  home.packages = with pkgs;[
    gh
    vscode
    cloudflare-warp
    cachix
    firefox
    google-chrome
    gparted
    element-desktop
    discord
    slack
    vlc
    i3lock
    zoom-us
    obsidian
    docker-compose
    light
    inputs.llm-agents.packages.${pkgs.system}.claude-code
    inputs.llm-agents.packages.${pkgs.system}.copilot-cli
    inputs.llm-agents.packages.${pkgs.system}.opencode
  ];

}

