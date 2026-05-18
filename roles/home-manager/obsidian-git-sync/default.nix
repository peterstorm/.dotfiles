{ config, pkgs, lib, ... }:

{
  systemd.user.services.obsidian-git-sync = {
    Unit = {
      Description = "Auto-sync Obsidian vault via git";
    };

    Service = {
      Type = "oneshot";
      WorkingDirectory = "${config.home.homeDirectory}/dev/notes";
      Environment = [
        "SSH_AUTH_SOCK=%t/ssh-agent"
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh"
      ];

      ExecStart = pkgs.writeShellScript "obsidian-git-sync" ''
        set -e

        # Commit local changes BEFORE pulling so that untracked files
        # (created by reclaw skills, etc.) don't block the merge when
        # the remote has same-pathed files from another machine.
        if [ -n "$(${pkgs.git}/bin/git status --porcelain)" ]; then
          ${pkgs.git}/bin/git add -A
          ${pkgs.git}/bin/git commit -m "vault: auto-sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi

        ${pkgs.git}/bin/git pull --rebase --autostash
        ${pkgs.git}/bin/git push
      '';
    };
  };

  systemd.user.timers.obsidian-git-sync = {
    Unit = {
      Description = "Timer for Obsidian vault git sync";
    };

    Timer = {
      OnBootSec = "5min";
      OnUnitActiveSec = "30min";
      Persistent = true;
    };

    Install = {
      WantedBy = [ "timers.target" ];
    };
  };
}
