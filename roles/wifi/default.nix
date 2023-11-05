{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall.allowedTCPPorts = [ 8010 6443 ];
 services.avahi.enable = true;
}
