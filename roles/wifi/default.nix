{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall = {
  enable = false;
  # allowedTCPPorts = [ 8010 6443 80 443 ];
 };
 services.avahi.enable = true;
}
