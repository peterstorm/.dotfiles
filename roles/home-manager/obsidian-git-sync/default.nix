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
        # BatchMode: never block on a passphrase/host-key prompt — there is no
        # tty here, so a prompt would hang the unit until the timer's next run.
        "GIT_SSH_COMMAND=${pkgs.openssh}/bin/ssh -o BatchMode=yes"
        # Fail loudly if the remote ever resolves to HTTPS (no credential helper
        # is configured), instead of the opaque ENXIO from git opening /dev/tty.
        "GIT_TERMINAL_PROMPT=0"
      ];

      ExecStart = pkgs.writeShellScript "obsidian-git-sync" ''
        set -euo pipefail

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
