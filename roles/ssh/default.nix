{config, pkgs, lib, ...}:

{
  services.openssh = {
    enable = true;
    allowSFTP = false; # Don't set this if you need sftp
    hostKeys = [
      { path = "/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
    ];
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      KexAlgorithms = [ "curve25519-sha256" "curve25519-sha256@libssh.org" ];
      Ciphers = [ "aes256-gcm@openssh.com" "aes128-gcm@openssh.com" ];
      Macs = [ "hmac-sha2-512-etm@openssh.com" "hmac-sha2-256-etm@openssh.com" "umac-128-etm@openssh.com" "hmac-sha2-256" "hmac-sha2-512" ];
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

