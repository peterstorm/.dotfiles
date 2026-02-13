---
name: k8s-expert
description: This skill should be used when the user asks to "deploy to kubernetes", "debug pod issues", "configure ingress", "set up helm chart", "argocd sync", "kubectl commands", "service not working", "pod crashloopbackoff", "cilium config", "cilium ingress", "hubble", "ksops secrets", "sops encrypt", "cert-manager config", "troubleshoot k8s", "pvc pending", "cloudflared tunnel", "applicationset", "add app to cluster", or mentions k8s, kubernetes, kubectl, helm, argocd, k3s, cilium, homelab cluster, hetzner cluster. Provides comprehensive Kubernetes guidance including GitOps patterns from this dotfiles repo.
---

# Kubernetes Expert

Full-stack Kubernetes guidance: kubectl, Helm, ArgoCD GitOps, Cilium networking, ksops secrets, debugging. Includes patterns from this repo's `k8s/` homelab and Hetzner cluster setup.

## Architecture Overview

Two K3s single-node clusters sharing identical GitOps stack:

| Component | Tool | Notes |
|-----------|------|-------|
| **Distro** | K3s | `--disable servicelb,traefik,kube-proxy --flannel-backend=none` |
| **CNI** | Cilium | eBPF, replaces kube-proxy + flannel |
| **Load Balancer** | Cilium L2 Announcement | Replaces MetalLB |
| **Ingress** | Cilium native | `ingressClassName: cilium` |
| **GitOps** | ArgoCD + ApplicationSet | Git directory generator auto-discovers apps |
| **Secrets** | ksops + SOPS + age | Encrypted in git, decrypted by ArgoCD |
| **Certificates** | cert-manager | Let's Encrypt via Cloudflare DNS01 |
| **Tunnel** | Cloudflared | Expose services without port forwarding |
| **DNS** | Cloudflare (Terraform) | DNS records managed in `terraform-homelab/cloudflare/` |
| **Observability** | kube-prometheus-stack + Hubble | Grafana, Prometheus, Cilium network visibility |
| **Bootstrap** | NixOS K3s role + Terraform | NixOS configures K3s, Terraform bootstraps cluster components |
| **Storage** | hostPath | Single-node, `/var/data/` on host |

### Clusters

- **homelab** — local K3s on NixOS, LAN services + Cloudflare tunnel
- **hetzner** — bare metal Hetzner dedicated server, same stack, remote

## Quick Reference

### kubectl Essentials

```bash
# Pod debugging
kubectl get pods -A                           # all namespaces
kubectl describe pod <name> -n <ns>           # events, status
kubectl logs <pod> -n <ns> --previous         # crashed container logs
kubectl logs <pod> -c <container> -f          # follow specific container
kubectl exec -it <pod> -n <ns> -- /bin/sh     # shell into pod

# Resource inspection
kubectl get events -n <ns> --sort-by='.lastTimestamp'
kubectl top pods -n <ns>                      # resource usage
kubectl get all -n <ns>                       # everything in namespace

# Quick edits
kubectl edit deployment <name> -n <ns>
kubectl rollout restart deployment <name> -n <ns>
kubectl rollout status deployment <name> -n <ns>
kubectl rollout undo deployment <name> -n <ns>

# Ephemeral containers (debug without restart)
kubectl debug <pod> -it --image=busybox --target=<container>
kubectl debug <pod> -it --copy-to=debug-pod --image=nicolaka/netshoot
kubectl debug node/<node> -it --image=busybox
```

### Helm Commands

```bash
helm repo add <name> <url> && helm repo update
helm install <release> <chart> -n <ns> --create-namespace -f values.yaml
helm upgrade --install <release> <chart> -n <ns> -f values.yaml

# Debugging
helm list -A
helm get values <release> -n <ns>
helm get manifest <release> -n <ns>
helm template <chart> -f values.yaml          # dry-run render

# Rollback
helm history <release> -n <ns>
helm rollback <release> <revision> -n <ns>
```

### ArgoCD Operations

```bash
argocd login <server> --grpc-web
argocd app list
argocd app get <app>
argocd app sync <app> --prune
argocd app diff <app>
argocd app logs <app>
argocd app history <app>
```

## Repo Structure

```
k8s/
├── terraform-homelab/              # Terraform bootstrap (active)
│   ├── main.tf                     # Orchestrates all modules
│   ├── variables.tf
│   ├── helm-cilium/                # Cilium CNI install
│   ├── helm-cilium-l2/             # L2 announcement + IP pool
│   ├── helm-cert-manager/          # cert-manager install
│   ├── cert-manager-issuer/        # Let's Encrypt ClusterIssuer
│   ├── argocd/                     # ArgoCD Helm release + ksops config
│   ├── applicationset/             # Root ApplicationSet (git generator)
│   └── cloudflare/                 # DNS records via Cloudflare provider
└── argocd-homelab/                 # App manifests (auto-discovered)
    ├── cloudflared/                # Cloudflare tunnel (ksops secrets)
    ├── echo-server/                # Test app
    ├── plex/                       # Media server
    ├── transmission/               # Torrent client + NordVPN (ksops secrets)
    ├── sonarr/                     # TV management
    ├── radarr/                     # Movie management
    ├── prowlarr/                   # Indexer management
    ├── overseerr/                  # Media requests
    └── monitoring/                 # kube-prometheus-stack (Helm)
```

### ApplicationSet (Git Directory Generator)

The root ApplicationSet in `terraform-homelab/applicationset/appset.yaml` auto-creates an ArgoCD Application for each subdirectory in `k8s/argocd-homelab/`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]
  generators:
    - git:
        repoURL: https://github.com/peterstorm/.dotfiles.git
        revision: HEAD
        directories:
          - path: k8s/argocd-homelab/*
  template:
    metadata:
      name: "{{.path.basename}}"
    spec:
      project: default
      source:
        repoURL: https://github.com/peterstorm/.dotfiles.git
        targetRevision: HEAD
        path: "{{.path.path}}"
      destination:
        server: https://kubernetes.default.svc
        namespace: "{{.path.basename}}"
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
```

### Adding a New App

1. Create directory: `k8s/argocd-homelab/<app-name>/`
2. Add kustomization.yaml + manifests (or Chart.yaml for Helm)
3. If secrets needed: add `secrets.enc.yaml` + `secret-generator.yaml` (ksops)
4. Add DNS record in `terraform-homelab/cloudflare/main.tf`
5. Add cloudflared ingress rule if external access needed
6. Push to git — ApplicationSet auto-creates the ArgoCD Application

**Kustomize app example:**
```yaml
# k8s/argocd-homelab/my-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

**Helm app example (monitoring pattern):**
```yaml
# k8s/argocd-homelab/my-app/Chart.yaml
apiVersion: v2
name: my-app
version: 0.1.0
dependencies:
  - name: some-chart
    version: "1.2.3"
    repository: https://charts.example.com
```

## Secrets Management (ksops + SOPS + age)

### How It Works

1. Secrets encrypted with SOPS (age encryption) and committed to git
2. ArgoCD repo-server has ksops plugin + age key mounted
3. On sync, ksops decrypts secrets and applies them as regular k8s Secrets

### Age Key Setup

```bash
# NixOS host generates age key at /var/lib/sops-nix/keys.txt
# Systemd service syncs it to k8s:
# k3s-sops-age-key-sync → creates Secret "sops-age-key" in argocd namespace
```

### Creating Encrypted Secrets

```bash
# 1. Create plaintext secret YAML
cat <<EOF > secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
stringData:
  password: supersecret
EOF

# 2. Encrypt with SOPS
sops -e -i secrets.yaml
# Renamed to secrets.enc.yaml by convention

# 3. Create ksops generator
cat <<EOF > secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: secret-generator
files:
  - ./secrets.enc.yaml
EOF

# 4. Reference in kustomization.yaml
# generators:
#   - secret-generator.yaml
```

### Kustomization with ksops

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml
resources:
  - deployment.yaml
  - service.yaml
```

### ArgoCD ksops Configuration

ArgoCD repo-server configured in `terraform-homelab/argocd/values.yaml`:
- Init container copies ksops + kustomize binaries from `viaductoss/ksops:v4.3.2`
- Age key mounted from Secret `sops-age-key`
- `SOPS_AGE_KEY_FILE=/sops-age/keys.txt`
- kustomize build with `--enable-alpha-plugins --enable-exec`

## Networking (Cilium)

### Cilium Configuration

K3s starts with `--disable-kube-proxy --flannel-backend=none --disable-network-policy`.
Cilium replaces all of these:

```yaml
# Key values from helm-cilium/values.yaml
kubeProxyReplacement: true
k8sServiceHost: "127.0.0.1"
k8sServicePort: "6443"
l2announcements:
  enabled: true
externalIPs:
  enabled: true
ingressController:
  enabled: true
  loadbalancerMode: shared
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
ipam:
  mode: "kubernetes"
operator:
  replicas: 1
```

### L2 Load Balancer (replaces MetalLB)

```yaml
# CiliumLoadBalancerIPPool
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-pool
spec:
  blocks:
    - start: "192.168.0.240"
      stop: "192.168.0.250"

# CiliumL2AnnouncementPolicy
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2-announcement-policy
spec:
  loadBalancerIPs: true
  externalIPs: true
  interfaces:
    - ^.*
```

### Ingress (Cilium Native)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: cilium
  tls:
    - hosts:
        - my-app.peterstorm.io
      secretName: my-app-tls
  rules:
    - host: my-app.peterstorm.io
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
```

## Cert-Manager

### ClusterIssuer (Terraform-managed)

Let's Encrypt prod with Cloudflare DNS01 challenge:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: peterstorm@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
```

### Staging-First Workflow

```bash
# 1. Use staging issuer first (no rate limits)
cert-manager.io/cluster-issuer: letsencrypt-staging

# 2. Verify cert issued
kubectl get certificate -n <ns>

# 3. Switch to prod
cert-manager.io/cluster-issuer: letsencrypt-prod

# 4. Delete old secret to trigger re-issue
kubectl delete secret <tls-secret> -n <ns>
```

## Bootstrap Process

### 1. NixOS K3s Role

`roles/k3s/default.nix` configures K3s with Cilium-compatible flags and SOPS age key sync.

### 2. Terraform Bootstrap

```bash
cd ~/.dotfiles/k8s/terraform-homelab
terraform init
terraform apply -var="cloudflare_tunnel_id=<tunnel-id>"
```

Module dependency order:
1. `helm-cilium` → Cilium CNI
2. `helm-cilium-l2` → L2 announcement + IP pool (waits 30s for CRDs)
3. `helm-cert-manager` → cert-manager with CRDs
4. `cert-manager-issuer` → ClusterIssuer (depends on cert-manager)
5. `argocd` → ArgoCD + ksops config (depends on cilium-l2)
6. `applicationset` → Root ApplicationSet (depends on argocd)
7. `cloudflare` → DNS records (independent)

### Common Bootstrap Gotchas

- Delete stale flannel interface: `sudo ip link delete flannel.1`
- Flush old kube-proxy iptables rules
- Restart k3s after cleanup
- Wait 2-3 min for Cilium to stabilize, then restart kube-system pods
- Adopt ArgoCD CRDs if they exist from previous install (Helm label conflict)
- Use `/etc/rancher/k3s/k3s.yaml` directly (certs rotate on k3s restart)

## Hetzner Cluster

Bare metal Hetzner dedicated server running identical stack to homelab:

- **Same**: K3s, Cilium, ArgoCD, ksops, cert-manager, Cloudflared
- **Different**: remote access, no LAN services, all traffic via Cloudflare tunnel
- **Storage**: hostPath on dedicated server (single node)
- **Bootstrap**: same Terraform modules, separate `terraform-hetzner/` directory
- **DNS**: same Cloudflare Terraform provider, separate zone/records

### Multi-Cluster Considerations

- Separate ArgoCD ApplicationSet per cluster (`argocd-homelab/` vs `argocd-hetzner/`)
- Separate Terraform directories (`terraform-homelab/` vs `terraform-hetzner/`)
- Shared secrets structure in `secrets/hosts/<hostname>/`
- Same SOPS `.sops.yaml` with per-host age keys
- Cloudflared tunnel per cluster (separate tunnel IDs)
- Consider shared monitoring (federation or centralized Grafana)

## Debugging Workflows

### Pod Not Starting

```bash
kubectl get pod <pod> -n <ns> -o wide
kubectl describe pod <pod> -n <ns> | grep -A 20 Events

# ImagePullBackOff: wrong image/tag, missing imagePullSecrets
# Pending: insufficient resources, node selector mismatch
# CrashLoopBackOff: check logs with --previous
# CreateContainerConfigError: missing configmap/secret
```

### Service Not Reachable

```bash
kubectl get endpoints <svc> -n <ns>
kubectl get svc <svc> -n <ns> -o yaml | grep -A5 selector
kubectl get pods -n <ns> --show-labels
kubectl run debug --rm -it --image=busybox -- wget -qO- http://<svc>.<ns>.svc.cluster.local
```

### Cilium Issues

```bash
cilium status
cilium connectivity test
hubble observe -n <ns>                        # live traffic
kubectl get ciliumendpoints -n <ns>
kubectl logs -n kube-system -l k8s-app=cilium
```

## Additional Resources

### Reference Files

- **`references/troubleshooting.md`** — Extended debugging (pods, networking, storage, certs, ArgoCD, Cilium, ksops)
- **`references/helm-patterns.md`** — Helm chart best practices, ArgoCD+Helm integration
- **`references/homelab-components.md`** — Cilium, Cloudflared, ksops, kube-prometheus-stack, k9s details

### Key Config Files

- `k8s/terraform-homelab/main.tf` — Bootstrap orchestration
- `k8s/terraform-homelab/helm-cilium/values.yaml` — Cilium config
- `k8s/terraform-homelab/argocd/values.yaml` — ArgoCD + ksops config
- `k8s/terraform-homelab/applicationset/appset.yaml` — App discovery
- `k8s/argocd-homelab/*/kustomization.yaml` — Per-app manifests
- `roles/k3s/default.nix` — NixOS K3s service config
