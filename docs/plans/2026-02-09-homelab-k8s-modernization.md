# Homelab k8s Modernization

## Goal
Migrate homelab k3s from outdated stack to modern pattern matching Hetzner k3s setup.

## What Gets Removed
- flannel (default k3s CNI)
- ingress-nginx
- MetalLB
- cert-manager + Let's Encrypt
- external-dns
- external-secrets + Azure Key Vault dependency
- App of Apps pattern

## What Gets Added/Replaced
- Cilium CNI (kubeProxyReplacement, L2 announcements, ingress controller, Hubble)
- SOPS + ksops (age key from NixOS host)
- ApplicationSets (git directory generator)
- Terraform-managed Cloudflare DNS
- kube-prometheus-stack (Prometheus + Grafana + Alertmanager)
- *arr media stack (Sonarr, Radarr, Prowlarr, Overseerr)

## Bootstrap Order (Terraform)

### Phase 0: NixOS k3s Config
k3s flags: `--flannel-backend=none --disable-network-policy --disable servicelb --disable traefik`

### Phase 1: Terraform Bootstrap (sequential, depends_on chain)
1. **Cilium** (helm) — CNI must be first, pods can't schedule without it
2. **Cilium L2** — announcements + LB IP pool (192.168.0.240-250)
3. **ksops** — create k8s secret `sops-age-key` in argocd namespace from `/var/lib/sops-nix/keys.txt`
4. **ArgoCD** (helm) — with ksops repo-server patch
5. **Cloudflare tunnel** (API) — creates tunnel, gets credentials
6. **Cloudflare DNS** (API) — external CNAMEs + local A records
7. **Root ApplicationSet** — hands off to git

### Phase 2: ArgoCD Takes Over (git-driven)
ApplicationSets auto-discover directories under `k8s/argocd-homelab/`

## Directory Structure

```
k8s/
├── terraform-homelab/
│   ├── main.tf
│   ├── cilium/
│   │   └── main.tf
│   ├── argocd/
│   │   ├── main.tf
│   │   └── values.yaml
│   ├── cloudflare/
│   │   └── main.tf
│   └── ksops/
│       └── main.tf
│
├── argocd-homelab/
│   ├── appsets.yaml
│   ├── infra/
│   │   ├── cloudflared/
│   │   └── monitoring/
│   ├── apps/
│   │   └── echo-server/
│   └── media/
│       ├── plex/
│       ├── transmission/
│       ├── sonarr/
│       ├── radarr/
│       ├── prowlarr/
│       └── overseerr/
│
└── argocd/                    # OLD — delete after migration
```

## Networking

### External Traffic
```
internet → Cloudflare edge (TLS) → cloudflared pod → Cilium Ingress → ClusterIP
```

### Local Traffic
```
LAN → Cloudflare DNS A record → Cilium LB VIP (192.168.0.240) → Cilium Ingress → ClusterIP
```

### Plex (dedicated LB)
```
LAN → plex.peterstorm.io → 192.168.0.241 → Cilium L2 LB → Plex:32400
```

### DNS Records (Terraform-managed)
| Domain | Type | Target | Access |
|--------|------|--------|--------|
| echo-server.peterstorm.io | CNAME | tunnel-id.cfargotunnel.com | external |
| sonarr.peterstorm.io | A | 192.168.0.240 | local |
| radarr.peterstorm.io | A | 192.168.0.240 | local |
| prowlarr.peterstorm.io | A | 192.168.0.240 | local |
| overseerr.peterstorm.io | A | 192.168.0.240 | local |
| transmission.peterstorm.io | A | 192.168.0.240 | local |
| plex.peterstorm.io | A | 192.168.0.241 | local |
| grafana.peterstorm.io | A | 192.168.0.240 | local |
| argocd.peterstorm.io | A | 192.168.0.240 | local |

### Cilium Config
- kubeProxyReplacement: true
- l2announcements enabled, IP pool 192.168.0.240-250
- ingressController.enabled: true
- Hubble enabled (Prometheus metrics)

## Secrets — SOPS + ksops

### Bootstrap (Terraform)
1. Read `/var/lib/sops-nix/keys.txt`
2. Create k8s secret `sops-age-key` in argocd namespace
3. Patch ArgoCD repo-server: mount secret + ksops init container

### Per-app Pattern
```
argocd-homelab/media/sonarr/
├── values.yaml
├── secrets.enc.yaml
└── ksops-generator.yaml
```

### .sops.yaml Rule
```yaml
- path_regex: k8s/argocd-homelab/.*\.enc\.(yaml|json)$
  key_groups:
  - age:
    - *homelab
```

### Secrets to Migrate from Azure KV
- Cloudflare tunnel credentials
- Cloudflare API token
- NordVPN credentials (Transmission)

## Media Stack

### Storage Layout
```
/var/data/
├── configs/{plex,sonarr,radarr,prowlarr,overseerr,transmission}/
├── media/{tv,movies}/
└── torrents/{complete,incomplete}/
```

### Data Flow
```
Overseerr (request) → Sonarr/Radarr (search) → Prowlarr (indexers)
  → Transmission (download) → Sonarr/Radarr (import+rename) → Plex (serve)
```

### Charts
All upstream charts, no Bitnami:
- Plex: linuxserver/plex (custom chart or raw manifests)
- Sonarr/Radarr/Prowlarr/Overseerr: k8s-at-home or raw manifests
- Transmission: haugene/transmission-openvpn

## Monitoring
- kube-prometheus-stack umbrella chart
- Grafana at grafana.peterstorm.io (local)
- Hubble metrics → Prometheus
- Default dashboards (node, pod, namespace)
- Alertmanager (no external targets initially)

## Migration Strategy
1. Build new terraform-homelab/ + argocd-homelab/ alongside existing k8s/
2. Wipe k3s cluster (single-node, no state to preserve except media files on /var/data)
3. Rebuild: NixOS apply → Terraform bootstrap → ArgoCD takes over
4. Delete old k8s/argocd/ and k8s/terraform/ directories

## Review Findings (Critical Fixes)

### 1. k3s Flags — update roles/k3s/default.nix
Current flags missing `--flannel-backend=none --disable-network-policy`. Without these, flannel conflicts with Cilium.

### 2. Cilium CRD Wait
L2AnnouncementPolicy + LoadBalancerIPPool CRDs need time to register after Cilium helm install. Add `null_resource` wait in Terraform between Cilium helm and L2 config.

### 3. Age Key Out of Terraform State
Don't read age key via `file()` in Terraform — leaks to state. Use NixOS systemd service instead:
```nix
systemd.services.argocd-sops-secret = {
  wantedBy = [ "k3s.service" ];
  after = [ "k3s.service" ];
  script = ''
    until kubectl get ns argocd &>/dev/null; do sleep 5; done
    kubectl create secret generic sops-age-key -n argocd \
      --from-file=/var/lib/sops-nix/keys.txt \
      --dry-run=client -o yaml | kubectl apply -f -
  '';
};
```

### 4. Local Traffic Routing — Cilium Ingress
Plan was vague on local traffic path. Use Cilium Ingress Controller with shared LB mode:
- All local services share 192.168.0.240 via host-based Ingress rules
- Plex gets dedicated LB IP via `io.cilium/lb-ipam-ips: "192.168.0.241"` annotation

### 5. k8s-at-home Charts Are Dead
Archived in 2022. Options: TrueCharts (maintained fork) or raw manifests. Recommend raw manifests for simplicity — *arr apps are simple Deployment+Service+PVC.

### 6. Storage — Per-App PVCs
Replace shared hostPath ReadWriteMany PV with:
- Per-app PVCs via local-path-provisioner (configs)
- Shared hostPath for `/var/data/media` and `/var/data/torrents` (data exchange between apps)

### 7. Pre-Migration Checklist
- [ ] Export secrets from Azure KV to SOPS before wipe
- [ ] Backup Plex metadata: `tar -czf plex-backup-$(date +%F).tar.gz /var/data/configs/plex`
- [ ] Update k3s NixOS flags
- [ ] Verify SOPS encryption works with homelab age key
