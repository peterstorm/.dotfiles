{pkgs, config, lib, ...}:
{
  programs.tmux = {
    enable = true;
    keyMode = "vi";
    extraConfig = ''
      # set colors correctly
      set -g default-terminal "tmux-256color"
      set -ag terminal-overrides ",xterm-256color:RGB"
      # Smart pane switching with awareness of Vim splits.
      # See: https://github.com/christoomey/vim-tmux-navigator
      is_vim="ps -o state= -o comm= -t '#{pane_tty}' \
        | grep -iqE '^[^TXZ ]+ +(\\S+\\/)?g?(view|n?vim?x?)(diff)?$'"
      bind-key -n C-h if-shell "$is_vim" "send-keys C-h"  "select-pane -L"
      bind-key -n C-j if-shell "$is_vim" "send-keys C-j"  "select-pane -D"
      bind-key -n C-k if-shell "$is_vim" "send-keys C-k"  "select-pane -U"
      bind-key -n C-l if-shell "$is_vim" "send-keys C-l"  "select-pane -R"
      bind-key -n C-\ if-shell "$is_vim" "send-keys C-\\" "select-pane -l"
      bind-key -T copy-mode-vi C-h select-pane -L
      bind-key -T copy-mode-vi C-j select-pane -D
      bind-key -T copy-mode-vi C-k select-pane -U
      bind-key -T copy-mode-vi C-l select-pane -R
      bind-key -T copy-mode-vi C-\ select-pane -l
      bind C-l send-keys 'C-l'

      # Bind CTRL+Z to zoom current pane
      unbind-key C-z
      bind-key -n C-z resize-pane -Z
    '';
  };

  home.file = {
    ".tmux.sh".source = ./.tmux.sh;
  };
}

