# Phase 0+1: Homelab k8s Modernization

## Context
Migrating homelab k3s from flannel/MetalLB/external-secrets(Azure KV)/app-of-apps to Cilium/SOPS-ksops/ApplicationSets/Terraform-managed Cloudflare DNS. Cluster will be wiped and rebuilt fresh.

## Phase 0: NixOS k3s Role Update

**File: `roles/k3s/default.nix`** (modify)

Two changes:

### 0a. Add Cilium-required flags
Add `--flannel-backend=none --disable-network-policy` to `extraFlags`.

### 0b. Add systemd service for SOPS age key sync
Oneshot service `k3s-sops-age-key-sync` that:
- Runs after `k3s.service`
- Waits for `argocd` namespace to exist (loop with sleep)
- Creates/updates `sops-age-key` secret in argocd namespace from `/var/lib/sops-nix/keys.txt`
- Uses `k3s kubectl` (bundled with k3s, no separate kubectl pkg needed)
- `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`

This keeps the age key out of Terraform state (review finding #3).

---

## Phase 1: Terraform Bootstrap

**New directory: `k8s/terraform-homelab/`**

### File tree
```
k8s/terraform-homelab/
├── main.tf              # providers + module orchestration
├── variables.tf         # cloudflare_zone_id, cloudflare_tunnel_id
├── cilium/
│   ├── main.tf          # helm_release cilium
│   └── values.yaml      # Cilium config
├── cilium-l2/
│   ├── main.tf          # time_sleep + kubectl_manifest x2
│   ├── ip-pool.yaml     # CiliumLoadBalancerIPPool 192.168.0.240-250
│   └── l2-policy.yaml   # CiliumL2AnnouncementPolicy
├── argocd/
│   ├── main.tf          # helm_release argocd
│   └── values.yaml      # ArgoCD + ksops repo-server config
├── cloudflare/
│   └── main.tf          # DNS records (A + CNAME)
└── applicationset/
    ├── main.tf          # kubectl_manifest
    └── appset.yaml      # Git directory generator -> k8s/argocd-homelab/*
```

### 1a. Root `main.tf`
Providers: `helm`, `kubectl` (alekc), `cloudflare`, `time`
All use `~/.kube/config`. Cloudflare uses `CLOUDFLARE_API_TOKEN` env var.

Module dependency chain:
```
cilium -> cilium-l2 -> argocd -> applicationset
cloudflare (independent, no depends_on)
```

### 1b. Cilium helm release
- Chart: `cilium/cilium` from `https://helm.cilium.io/`
- Namespace: `kube-system`
- Key values:
  - `kubeProxyReplacement: true`
  - `k8sServiceHost: "127.0.0.1"` / `k8sServicePort: "6443"` (k3s)
  - `l2announcements.enabled: true`
  - `externalIPs.enabled: true`
  - `ingressController.enabled: true` + `loadbalancerMode: shared`
  - `hubble.enabled: true` + relay + ui
  - `operator.replicas: 1` (single node)
  - `ipam.mode: "kubernetes"`

### 1c. Cilium L2 config
- `time_sleep` 30s after Cilium helm (CRDs need registration time - review finding #2)
- `CiliumLoadBalancerIPPool`: 192.168.0.240-250
- `CiliumL2AnnouncementPolicy`: all interfaces

### 1d. ArgoCD helm release
- Chart: `argo-cd` from `https://argoproj.github.io/argo-helm`
- Namespace: `argocd` (create_namespace=true, triggers NixOS systemd service)
- `server.extraArgs: [--insecure]` (matches existing config)
- ksops repo-server patch:
  - initContainer: `viaductoss/ksops:v4.3.2` copies ksops+kustomize to emptyDir
  - volumeMounts: custom-tools (ksops/kustomize binaries) + sops-age-key secret
  - env: `SOPS_AGE_KEY_FILE=/sops-age/keys.txt`

### 1e. Cloudflare DNS
- Provider uses `CLOUDFLARE_API_TOKEN` env var
- `zone_id` via `TF_VAR_cloudflare_zone_id`
- Records:
  - `echo-server` -> CNAME -> `{tunnel_id}.cfargotunnel.com` (proxied)
  - `sonarr,radarr,prowlarr,overseerr,transmission,grafana,argocd` -> A -> 192.168.0.240 (not proxied)
  - `plex` -> A -> 192.168.0.241 (not proxied, dedicated LB IP)

### 1f. Root ApplicationSet
- Git directory generator: `k8s/argocd-homelab/*`
- Auto-creates Application per subdirectory
- syncPolicy: automated prune + selfHeal + CreateNamespace

---

## Verification

1. `git add .` all new files
2. `nix build .#nixosConfigurations.homelab.config.system.build.toplevel --dry-run --show-trace` -- validate NixOS build
3. After cluster wipe + NixOS apply + Terraform:
   - `kubectl get pods -n kube-system` -- Cilium pods running
   - `kubectl get ciliumloadbalancerippool` -- IP pool exists
   - `kubectl get pods -n argocd` -- ArgoCD running
   - `kubectl get secret sops-age-key -n argocd` -- age key present
   - `kubectl get applicationset -n argocd` -- root appset exists
   - `nslookup argocd.peterstorm.io` -- DNS resolves

---

## Unresolved Questions
- Cilium chart version to pin? (will use latest stable)
- ArgoCD chart version to pin? (will use recent stable)
- `k3s-uninstall.sh` full reset or just clear CNI dirs?
