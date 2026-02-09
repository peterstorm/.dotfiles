# Homelab K8s Deployment

## Prerequisites

- Age key at `/var/lib/sops-nix/keys.txt` on homelab
- SOPS secrets populated: `sops secrets/hosts/homelab/cloudflare.yaml` (api_token, zone_id, account_id)
- Cloudflare tunnel `homelab-k8s` already exists (tunnel ID: `206b7a4a-a658-437d-a98b-c14c6e4cc286`)

## Full Deploy (from scratch)

### 1. Wipe existing cluster (on homelab)

```bash
sudo /usr/local/bin/k3s-uninstall.sh
```

### 2. NixOS rebuild (on homelab)

```bash
cd ~/.dotfiles
git pull
sudo nixos-rebuild switch --flake .#homelab
```

Wait for k3s to start:

```bash
systemctl status k3s
sudo k3s kubectl get nodes  # should show Ready after ~30s
```

### 3. Set kubeconfig (on homelab)

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

Or from local machine:

```bash
scp homelab:/etc/rancher/k3s/k3s.yaml ~/.kube/homelab.yaml
# edit server URL: 127.0.0.1 -> homelab IP
export KUBECONFIG=~/.kube/homelab.yaml
```

### 4. Terraform bootstrap (where kubectl works)

```bash
cd ~/.dotfiles/k8s/terraform-homelab
terraform init
terraform apply -var="cloudflare_tunnel_id=206b7a4a-a658-437d-a98b-c14c6e4cc286"
```

This installs (in order): Cilium → Cilium L2 config → ArgoCD → ApplicationSet → Cloudflare DNS records.

Wait for Cilium + ArgoCD to be ready (~2-3 min).

### 5. Verify

```bash
# Cilium
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-agent

# ArgoCD
kubectl get pods -n argocd

# SOPS age key synced to argocd namespace
kubectl get secret sops-age-key -n argocd

# ApplicationSet created
kubectl get applicationset -n argocd

# All apps discovered and syncing
kubectl get applications -n argocd

# Check app health
kubectl get applications -n argocd -o wide
```

### 6. Access ArgoCD

```bash
# Get admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo

# URL (via cloudflared tunnel)
# https://argocd.peterstorm.io
# user: admin
```

## Service URLs

### External (via Cloudflare tunnel)

| Service | URL |
|---------|-----|
| ArgoCD | https://argocd.peterstorm.io |
| Echo Server | https://echo-server.peterstorm.io |
| Grafana | https://grafana.peterstorm.io |
| Sonarr | https://sonarr.peterstorm.io |
| Radarr | https://radarr.peterstorm.io |
| Prowlarr | https://prowlarr.peterstorm.io |
| Overseerr | https://overseerr.peterstorm.io |
| Transmission | https://transmission.peterstorm.io |

### LAN (via Cilium Ingress on 192.168.0.240)

Same hostnames resolve to `192.168.0.240` via Cloudflare DNS (not proxied).
Requires DNS or `/etc/hosts` pointing `*.peterstorm.io` to `192.168.0.240`.

| Service | URL |
|---------|-----|
| Plex | http://192.168.0.241:32400 |

## Troubleshooting

```bash
# App not syncing
kubectl -n argocd get app <app-name> -o yaml | grep -A5 status

# ksops decryption failing
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-repo-server | grep -i sops

# Cloudflared not connecting
kubectl -n cloudflared logs -l app=cloudflared

# Pod stuck
kubectl -n <namespace> describe pod -l app=<app>

# Cilium issues
kubectl -n kube-system exec ds/cilium -- cilium status
```

## Architecture

```
terraform-homelab/     # Bootstrap: Cilium, ArgoCD, DNS, ApplicationSet
argocd-homelab/        # App manifests (auto-discovered by ApplicationSet)
  cloudflared/         # Tunnel ingress (ksops secrets)
  echo-server/         # Smoke test
  plex/                # LoadBalancer 192.168.0.241
  transmission/        # VPN + ksops secrets
  sonarr/              # TV management
  radarr/              # Movie management
  prowlarr/            # Indexer management
  overseerr/           # Request management
  monitoring/          # kube-prometheus-stack (helm)
```
