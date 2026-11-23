# Homelab network identity, declared. The router sits out of cable reach, so
# the node must keep its addresses on Wi-Fi alone and take the cable back
# without a fight when it is plugged in.
#
# Invariants (everything else in the repo assumes them):
#   192.168.0.28  node identity — k3s --node-ip/--advertise-address
#                 (roles/k3s), Cilium k8sServiceHost, cloudflared origins,
#                 SSH aliases. Held by BOTH NICs at once.
#   192.168.0.29  transmission Service externalIP (SOCKS :1080 / HTTP :3128,
#                 k8s/argocd-homelab/transmission). Held by Wi-Fi.
#
# Ethernet is preferred while plugged (route metric 50 vs NetworkManager's
# Wi-Fi default 600); unplugging it leaves .28 already up on Wi-Fi, so the
# only cost is the router re-learning .28's MAC (measured < 7 s of IPv4).
#
# ipv4.dad-timeout = 0 on every profile: NetworkManager's address-conflict
# probe sees the *other NIC of this same host* answering for .28 and refuses
# the address — that is what left eno1 without IPv4 on replug (2026-11-23).
#
# The Zyxel reservations (.28 -> eno1 MAC, .29 -> wlp3s0 MAC) keep both
# addresses away from other DHCP clients; Wi-Fi does not ask DHCP for them.
# See vault: homelab/network/zyxel-ex3600-router-migration.
{ config, lib, util, ... }:

let
  gateway = "192.168.0.1";

  # The two SSIDs are one router with one PSK; 5 GHz wins, 2.4 GHz is reach.
  wifiProfile = { id, ssid, priority }: {
    connection = {
      inherit id;
      type = "wifi";
      interface-name = "wlp3s0";
      autoconnect = true;
      autoconnect-priority = priority;
    };
    wifi = {
      inherit ssid;
      mode = "infrastructure";
    };
    wifi-security = {
      key-mgmt = "wpa-psk";
      psk = "$FREEBRITNEY_PSK"; # envsubst'd from the sops template below
    };
    ipv4 = {
      method = "manual";
      # address1 is primary: it is the source address for the subnet route.
      address1 = "192.168.0.28/24,${gateway}";
      address2 = "192.168.0.29/24";
      dns = "${gateway};";
      dns-search = "home;";
      dad-timeout = 0;
    };
    ipv6.method = "auto";
  };
in
(util.sops.mkSecretsAndTemplatesConfig
  [
    (util.sops.hostSecret "freebritney-psk" "wifi.yaml" "freebritney-psk" { owner = null; group = null; })
  ]
  [
    {
      # systemd EnvironmentFile for NetworkManager-ensure-profiles.
      name = "networkmanager-wifi-env";
      content = "FREEBRITNEY_PSK=${config.sops.placeholder."freebritney-psk"}\n";
      owner = "root";
      group = "root";
      mode = "0400";
    }
  ]
  {
    networking.networkmanager.ensureProfiles = {
      environmentFiles = [ config.sops.templates."networkmanager-wifi-env".path ];
      profiles = {
        homelab-wifi-5g = wifiProfile { id = "homelab-wifi-5g"; ssid = "FreeBritney5GHz"; priority = 10; };
        homelab-wifi-2g = wifiProfile { id = "homelab-wifi-2g"; ssid = "FreeBritney"; priority = 0; };

        homelab-wired = {
          connection = {
            id = "homelab-wired";
            type = "ethernet";
            interface-name = "eno1";
            autoconnect = true;
          };
          ipv4 = {
            method = "auto"; # the router's reservation hands eno1 .28
            route-metric = 50;
            dad-timeout = 0;
          };
          ipv6.method = "auto";
        };
      };
    };
  }
) { inherit config lib; }
