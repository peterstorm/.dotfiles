{ config, pkgs, lib, ... }:

{
  systemd.user.services.obsidian-git-sync = {
    Unit = {
      Description = "Auto-sync Obsidian vault via git";
      After = [ "network-online.target" ];
    };

    Service = {
      Type = "oneshot";
      WorkingDirectory = "${config.home.homeDirectory}/dev/notes";
      Environment = [
        "SSH_AUTH_SOCK=%t/ssh-agent"
        # Fail loudly if the remote ever resolves to HTTPS (no credential helper
        # is configured), instead of the opaque ENXIO from git opening /dev/tty.
        "GIT_TERMINAL_PROMPT=0"
      ];

      ExecStart = pkgs.writeShellScript "obsidian-git-sync" ''
        set -euo pipefail

        # Keep the command with spaces in the shell, not systemd Environment=,
        # otherwise systemd parses the `-o` argument as a bogus assignment.
        export GIT_SSH_COMMAND="${pkgs.openssh}/bin/ssh -o BatchMode=yes"

        # Commit local changes BEFORE pulling so that untracked files
        # (created by reclaw skills, etc.) don't block the merge when
        # the remote has same-pathed files from another machine.
        if [ -n "$(${pkgs.git}/bin/git status --porcelain)" ]; then
          ${pkgs.git}/bin/git add -A
          ${pkgs.git}/bin/git commit -m "vault: auto-sync $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        fi

        # A conflicted rebase left in progress would poison every later run
        # (the commit step above would run mid-rebase). Unwind it and fail —
        # a real conflict needs a human, but the repo stays in a known state.
        if ! ${pkgs.git}/bin/git pull --rebase --autostash; then
          ${pkgs.git}/bin/git rebase --abort || true
          echo "obsidian-git-sync: pull failed; rebase unwound, resolve by hand" >&2
          exit 1
        fi

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
