{config, pkgs, lib, ...}:

{
  services.openssh = {
    enable = true;
    allowSFTP = false; # Don't set this if you need sftp
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    extraConfig = ''
     AllowTcpForwarding yes
     X11Forwarding no
     AllowAgentForwarding no
     AllowStreamLocalForwarding no
     AuthenticationMethods publickey
   '';
  };

}

