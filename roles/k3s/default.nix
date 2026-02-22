{config, pkgs, lib, ...}:

{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = "--disable servicelb --disable traefik --disable-kube-proxy --write-kubeconfig-mode=644 --flannel-backend=none --disable-network-policy";
  };

  # Cilium manages its own network security via BPF; NixOS iptables firewall
  # conflicts with Cilium's datapath and blocks pod-to-host traffic.
  networking.firewall.enable = lib.mkForce false;

  systemd.services.k3s-sops-age-key-sync = {
    description = "Sync SOPS age key to argocd namespace";
    after = [ "k3s.service" ];
    requires = [ "k3s.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "KUBECONFIG=/etc/rancher/k3s/k3s.yaml";
    };
    path = [ config.services.k3s.package ];
    script = ''
      # wait for argocd namespace
      while ! k3s kubectl get namespace argocd >/dev/null 2>&1; do
        echo "Waiting for argocd namespace..."
        sleep 5
      done

      # create/update sops-age-key secret
      k3s kubectl create secret generic sops-age-key \
        --namespace=argocd \
        --from-file=keys.txt=/var/lib/sops-nix/keys.txt \
        --dry-run=client -o yaml | k3s kubectl apply -f -
    '';
  };
}
