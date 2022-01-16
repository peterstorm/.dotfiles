{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall.allowedTCPPorts = [ 8010 ];
 services.avahi.enable = true;
}
