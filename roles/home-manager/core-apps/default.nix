{pkgs, config, lib, inputs, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    matchBlocks = {
      homelab = {
        hostname = "192.168.0.28";
        user = "peterstorm";
      };
    };
  };

  services.ssh-agent.enable = true;

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
    shellAliases = {
      lock = "i3lock -c 000000";
      sus = "systemctl suspend";
      warpc = "warp-cli connect";
      warpd = "warp-cli disconnect";
      system-apply = "cd /home/peterstorm/.dotfiles && ./system-apply.sh";
      hm-apply = "cd /home/peterstorm/.dotfiles && ./hm-apply.sh";
    };
  };

  home.packages = with pkgs;[
    jq
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
    bun
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.claude-code
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.copilot-cli
    inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.opencode
    antigravity
  ];

}

