{config, pkgs, lib, ...}:

{
  services.openssh = {
    enable = true;
   passwordAuthentication = false;
   allowSFTP = false; # Don't set this if you need sftp
   challengeResponseAuthentication = false;
   extraConfig = ''
     AllowTcpForwarding yes
     X11Forwarding no
     AllowAgentForwarding no
     AllowStreamLocalForwarding no
     AuthenticationMethods publickey
   '';
  };

  users.users.user = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];

    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ+2TgMEWwmsE5i/kEHHo7iJyD4BzItKMakGg2AcbgyH nixos"
    ];
  };

}

