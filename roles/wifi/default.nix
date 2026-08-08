{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall = {
  enable = true;
    allowedTCPPorts = [ 8081 ];
 };
 services.avahi.enable = true;

 # Resolve `.local` hostnames (mDNS) so `ssh desktop.local` works from any of
 # these machines. This is resolution only — publishing (announcing your own
 # name) is deliberately left to hosts that opt in (see machines/desktop), so a
 # laptop on a strange network stays quiet but can still reach the LAN boxes.
 services.avahi.nssmdns4 = true;
}
