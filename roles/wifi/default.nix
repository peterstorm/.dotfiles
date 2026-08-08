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
 #
 # Both families on purpose: consumer APs often don't forward IPv4 mDNS
 # multicast (224.0.0.251) between wireless clients, but IPv6 link-local mDNS
 # (ff02::fb) gets through — so without nssmdns6 the name resolves to nothing
 # even though the host is reachable. With it, `.local` resolves to the IPv6
 # link-local (scoped to the interface) and ssh connects over that.
 services.avahi.nssmdns4 = true;
 services.avahi.nssmdns6 = true;
}
