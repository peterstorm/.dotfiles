# Phase 2: argocd-homelab Apps + k3s Fix

## Context
Phase 0+1 complete (k3s role + terraform-homelab bootstrap). ApplicationSet watches `k8s/argocd-homelab/*` but that dir is empty. Need to populate with all apps.

## Key Decisions
- **cloudflared**: routes directly to ClusterIP services (no double-proxy)
- **Cilium Ingress**: local LAN traffic only (hostname routing via L2 VIP 192.168.0.240)
- **Storage**: direct `hostPath` volumes per Deployment (single-node, no PV/PVC indirection needed)
- **Secrets**: ksops pattern — `secret-generator.yaml` + `secrets.enc.yaml` per app
- **Images**: pinned tags
- ***arr apps**: raw manifests (Deployment+Service+Ingress)
- **monitoring**: kube-prometheus-stack via helm (Chart.yaml in directory, ArgoCD auto-detects)

## Storage Layout (hostPath, all on /var/data)
```
/var/data/
├── configs/{plex,sonarr,radarr,prowlarr,overseerr,transmission}/
├── media/{tv,movies}/
└── torrents/{complete,incomplete}/
```

Each app mounts what it needs via hostPath directly in the Deployment spec.

---

## Changes

### 0. Fix k3s role
**File: `roles/k3s/default.nix`** (modify)
- Add `--disable-kube-proxy` to extraFlags (required for Cilium kubeProxyReplacement)

### 1. Add .sops.yaml rule
**File: `.sops.yaml`** (modify)
```yaml
- path_regex: k8s/argocd-homelab/.*\.enc\.(yaml|json)$
  key_groups:
    - age:
        - *homelab
```

### 2. `k8s/argocd-homelab/cloudflared/`
```
cloudflared/
├── kustomization.yaml
├── deployment.yaml         # cloudflare/cloudflared:2024.12.2
├── configmap.yaml          # ingress rules: hostname -> svc/app.ns:port
├── secret-generator.yaml   # ksops
└── secrets.enc.yaml        # SOPS-encrypted tunnel credentials JSON
```

Ingress rules in configmap:
- `echo-server.peterstorm.io` -> `http://echo-server.echo-server:80`
- `argocd.peterstorm.io` -> `http://argocd-server.argocd:80`
- `grafana.peterstorm.io` -> `http://kube-prometheus-stack-grafana.monitoring:80`
- catch-all -> `http_status:404`

Tunnel credentials: encrypt the JSON (`{"AccountTag":"...","TunnelID":"...","TunnelSecret":"..."}`) with SOPS. ksops decrypts at ArgoCD sync time. Remove the NixOS systemd cloudflared-creds-sync — ksops handles it.

### 3. `k8s/argocd-homelab/echo-server/`
```
echo-server/
├── kustomization.yaml
├── deployment.yaml         # ealen/echo-server:0.9.2, 1 replica
├── service.yaml            # ClusterIP:80
└── ingress.yaml            # Cilium Ingress, host: echo-server.peterstorm.io
```

Smoke test. Accessible externally via cloudflared + locally via Cilium Ingress.

### 4. `k8s/argocd-homelab/plex/`
```
plex/
├── kustomization.yaml
├── deployment.yaml         # linuxserver/plex:1.42.1, Recreate strategy
└── service.yaml            # LoadBalancer, io.cilium/lb-ipam-ips: "192.168.0.241"
```

- hostPath volumes: `/var/data/configs/plex`, `/var/data/media`
- Env: PUID=1000, PGID=1000, TZ=Europe/Copenhagen, PLEX_CLAIM (set at first boot, remove after)
- Dedicated LB IP via Cilium IPAM annotation

### 5. `k8s/argocd-homelab/transmission/`
```
transmission/
├── kustomization.yaml
├── deployment.yaml         # haugene/transmission-openvpn:5.2
├── service.yaml            # ClusterIP:80
├── ingress.yaml            # Cilium Ingress, host: transmission.peterstorm.io
├── secret-generator.yaml   # ksops
└── secrets.enc.yaml        # openvpn username/password
```

- NordVPN, TCP, SE, P2P. NET_ADMIN cap, /dev/net/tun hostPath
- hostPath: `/var/data/configs/transmission`, `/var/data/torrents`, `/var/data/media`

### 6-9. `k8s/argocd-homelab/{sonarr,radarr,prowlarr,overseerr}/`

All follow same pattern:
```
<app>/
├── kustomization.yaml
├── deployment.yaml         # linuxserver/<app>:<pinned-tag>
├── service.yaml            # ClusterIP:<app-port>
└── ingress.yaml            # Cilium Ingress, host: <app>.peterstorm.io
```

| App | Image | Port | Volumes |
|-----|-------|------|---------|
| sonarr | linuxserver/sonarr:4.0.13 | 8989 | configs/sonarr, media, torrents |
| radarr | linuxserver/radarr:5.18.4 | 7878 | configs/radarr, media, torrents |
| prowlarr | linuxserver/prowlarr:1.30.2 | 9696 | configs/prowlarr |
| overseerr | linuxserver/overseerr:1.33.2 | 5055 | configs/overseerr |

All: PUID=1000, PGID=1000, TZ=Europe/Copenhagen, Recreate strategy.

### 10. `k8s/argocd-homelab/monitoring/`
```
monitoring/
├── Chart.yaml              # dependency: kube-prometheus-stack
└── values.yaml             # Grafana ingress, retention, operator replicas=1
```

ArgoCD auto-detects Chart.yaml and uses helm. Values:
- `grafana.enabled: true`
- `alertmanager.enabled: true` (no external targets initially)
- `prometheus.prometheusSpec.retention: 7d`
- `prometheus.prometheusSpec.storageSpec`: hostPath or emptyDir (for now)
- Grafana: admin password via default secret, no persistence needed initially

---

## File Tree

```
roles/k3s/default.nix                              # modify: add --disable-kube-proxy
.sops.yaml                                          # modify: add argocd-homelab rule

k8s/argocd-homelab/
├── cloudflared/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── configmap.yaml
│   ├── secret-generator.yaml
│   └── secrets.enc.yaml          # encrypt after creating
├── echo-server/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── plex/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   └── service.yaml
├── transmission/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── secret-generator.yaml
│   └── secrets.enc.yaml          # encrypt after creating
├── sonarr/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── radarr/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── prowlarr/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── overseerr/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
└── monitoring/
    ├── Chart.yaml
    └── values.yaml
```

## Verification

1. `git add .` all new files
2. `nix build .#nixosConfigurations.homelab.config.system.build.toplevel --dry-run --show-trace` — k3s role
3. Encrypt secrets: `sops -e -i k8s/argocd-homelab/cloudflared/secrets.enc.yaml` (and transmission)
4. After cluster wipe + NixOS apply + Terraform bootstrap:
   - `kubectl get applicationset -n argocd` — root appset discovers dirs
   - `kubectl get apps -n argocd` — one Application per directory
   - `curl echo-server.peterstorm.io` — works via cloudflared
   - `curl http://echo-server.peterstorm.io` from LAN — works via Cilium Ingress (192.168.0.240)
   - Plex at `192.168.0.241:32400`
   - All *arr UIs accessible at `*.peterstorm.io` from LAN

## Unresolved Questions
- Image tags: I picked current stable versions; verify these are correct for ARM if homelab is ARM-based (old plex values suggest ARM)
- Monitoring storage: start with emptyDir (data lost on restart) or hostPath persistence?
