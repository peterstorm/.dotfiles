{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall = {
  enable = true;
    allowedTCPPorts = [ 8081 ];
 };
 services.avahi.enable = true;
}
