{ ...}:
{

 networking.networkmanager.enable = true;
 networking.firewall = {
  enable = true;
  # allowedTCPPorts = [ 8010 6443 80 443 ];
 };
 services.avahi.enable = true;
}
