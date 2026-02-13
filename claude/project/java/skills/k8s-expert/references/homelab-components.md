# Homelab & Hetzner Components

Detailed component documentation for the K3s clusters in this repo.

## Cilium CNI

Replaces flannel (CNI), kube-proxy (eBPF), and MetalLB (L2 announcement). Single component for networking, load balancing, ingress, and observability.

### K3s Flags (Prerequisites)

K3s must disable built-in networking for Cilium to take over:

```bash
# From roles/k3s/default.nix
--disable servicelb        # Cilium L2 replaces klipper
--disable traefik          # Cilium ingress replaces traefik
--disable-kube-proxy       # Cilium eBPF replaces kube-proxy
--flannel-backend=none     # Cilium replaces flannel
--disable-network-policy   # Cilium handles network policies
```

### Cilium Helm Values

Key settings from `terraform-homelab/helm-cilium/values.yaml`:

```yaml
kubeProxyReplacement: true           # eBPF datapath
k8sServiceHost: "127.0.0.1"         # K3s API on localhost
k8sServicePort: "6443"

l2announcements:
  enabled: true                       # ARP-based LB (replaces MetalLB)

externalIPs:
  enabled: true

ingressController:
  enabled: true                       # Native ingress controller
  loadbalancerMode: shared            # Single LB IP for all ingresses

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true                     # Network visibility dashboard

ipam:
  mode: "kubernetes"
operator:
  replicas: 1                         # Single node
```

### L2 Load Balancer IP Pool

Defined in `terraform-homelab/helm-cilium-l2/`:

```yaml
# CiliumLoadBalancerIPPool — defines available IPs
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata:
  name: homelab-pool
spec:
  blocks:
    - start: "192.168.0.240"
      stop: "192.168.0.250"

# CiliumL2AnnouncementPolicy — enables ARP responses
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: default-l2-announcement-policy
spec:
  loadBalancerIPs: true
  externalIPs: true
  interfaces:
    - ^.*                              # All interfaces
```

**Current IP assignments:**
- `192.168.0.241` — Plex (dedicated LoadBalancer)
- `192.168.0.242` — Shared LB for argocd, grafana, sonarr, radarr, prowlarr, overseerr, transmission

### Cilium Ingress

Uses `ingressClassName: cilium` instead of nginx. All services use shared LoadBalancer mode.

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
    - hosts: [my-app.peterstorm.io]
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

### Hubble (Network Observability)

```bash
# Install Hubble CLI
export HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz
tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin

# Port-forward Hubble relay
cilium hubble port-forward &

# Observe traffic
hubble observe                         # all traffic
hubble observe -n <ns>                 # namespace filter
hubble observe --verdict DROPPED       # dropped packets
hubble observe --to-service <svc>      # traffic to service
hubble observe -t l7                   # L7 (HTTP) flows

# Hubble UI (port-forward)
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# Open http://localhost:12000
```

### Troubleshooting Cilium

```bash
# Overall status
cilium status

# Connectivity test (creates test pods, validates CNI)
cilium connectivity test

# Check Cilium endpoints (should match pod count)
kubectl get ciliumendpoints -A

# Check agent logs
kubectl logs -n kube-system -l k8s-app=cilium --tail=100

# Check operator logs
kubectl logs -n kube-system -l name=cilium-operator --tail=100

# Verify L2 announcements working
kubectl get svc -A | grep LoadBalancer   # should have EXTERNAL-IP
arping -I <interface> 192.168.0.242      # should get ARP reply

# Restart Cilium (nuclear option)
kubectl rollout restart daemonset/cilium -n kube-system
```

## Cloudflared (Tunnel)

Secure tunnel to expose services without opening firewall ports.

```
Internet → Cloudflare Edge → Tunnel → cloudflared pod → k8s Service
```

### Deployment

Located in `k8s/argocd-homelab/cloudflared/`:
- `deployment.yaml` — cloudflared pod (image: `cloudflare/cloudflared:2024.12.2`)
- `configmap.yaml` — tunnel ingress routing rules
- `secrets.enc.yaml` — encrypted tunnel credentials (ksops)
- `secret-generator.yaml` — ksops generator
- `kustomization.yaml` — ties it together

### Tunnel Routing Config

From the cloudflared ConfigMap:

```yaml
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/creds/credentials.json
ingress:
  - hostname: echo-server.peterstorm.io
    service: http://echo-server.echo-server:80
  - hostname: argocd.peterstorm.io
    service: http://argocd-server.argocd:80
  - hostname: grafana.peterstorm.io
    service: http://kube-prometheus-stack-grafana.monitoring:80
  - hostname: sonarr.peterstorm.io
    service: http://sonarr.sonarr:8989
  - hostname: radarr.peterstorm.io
    service: http://radarr.radarr:7878
  - hostname: prowlarr.peterstorm.io
    service: http://prowlarr.prowlarr:9696
  - hostname: overseerr.peterstorm.io
    service: http://overseerr.overseerr:5055
  - hostname: transmission.peterstorm.io
    service: http://transmission.transmission:80
  - service: http_status:404
```

### Adding a New Tunnel Route

1. Add ingress rule to cloudflared ConfigMap
2. Add DNS CNAME in `terraform-homelab/cloudflare/main.tf` (proxied, pointing to tunnel)
3. Push — ArgoCD syncs cloudflared, Terraform applies DNS

### Creating a New Tunnel

```bash
cloudflared tunnel login
cloudflared tunnel create <tunnel-name>
# Outputs tunnel ID + credentials JSON

# Store credentials as encrypted k8s secret
# Add tunnel ID to Terraform variables
```

### Troubleshooting Cloudflared

```bash
kubectl logs -n cloudflared -l app=cloudflared
kubectl describe pod -n cloudflared -l app=cloudflared

# Verify tunnel connected
cloudflared tunnel info <tunnel-name>

# Test service reachability from within cluster
kubectl run curl --rm -it --image=curlimages/curl -- \
  curl -v http://echo-server.echo-server:80

# Common issues:
# - Credentials secret missing → ksops decryption failed
# - Service hostname/port mismatch in ConfigMap
# - DNS CNAME not proxied through Cloudflare
```

## ksops + SOPS + age (Secrets)

### Architecture

```
secrets.enc.yaml (git) → ksops (ArgoCD) → age decrypt → k8s Secret
```

### ArgoCD Repo-Server Config

From `terraform-homelab/argocd/values.yaml`:

```yaml
repoServer:
  initContainers:
    - name: install-ksops
      image: viaductoss/ksops:v4.3.2
      command: ["/bin/sh", "-c"]
      args: ["cp /usr/local/bin/ksops /custom-tools/ && cp /usr/local/bin/kustomize /custom-tools/"]
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools

  volumes:
    - name: custom-tools
      emptyDir: {}
    - name: sops-age-key
      secret:
        secretName: sops-age-key

  volumeMounts:
    - name: custom-tools
      mountPath: /usr/local/bin/ksops
      subPath: ksops
    - name: sops-age-key
      mountPath: /sops-age/keys.txt
      subPath: keys.txt

  env:
    - name: SOPS_AGE_KEY_FILE
      value: /sops-age/keys.txt
    - name: XDG_CONFIG_HOME
      value: /.config
```

### Age Key Sync (NixOS)

The `k3s-sops-age-key-sync` systemd service in `roles/k3s/default.nix` copies the host's SOPS age key to a k8s Secret in the argocd namespace:

```bash
# Key location on host
/var/lib/sops-nix/keys.txt

# Synced to k8s as:
kubectl get secret sops-age-key -n argocd
```

### File Conventions

```
k8s/argocd-homelab/<app>/
├── secrets.enc.yaml         # SOPS-encrypted Secret manifest
├── secret-generator.yaml    # ksops generator referencing ↑
├── kustomization.yaml       # generators: [secret-generator.yaml]
└── ...
```

## kube-prometheus-stack (Monitoring)

Located in `k8s/argocd-homelab/monitoring/`. Deployed as Helm chart via ArgoCD.

### Components

- **Prometheus** — metrics collection, 7-day retention, emptyDir storage
- **Grafana** — dashboards, exposed via Cilium ingress + Cloudflare tunnel
- **AlertManager** — alerting (emptyDir storage)
- **kube-state-metrics** — Kubernetes object metrics
- **node-exporter** — host-level metrics

### Access

- LAN: `http://grafana.peterstorm.io` (Cilium LB → 192.168.0.242)
- External: `https://grafana.peterstorm.io` (Cloudflare tunnel)

### Sync Options

The monitoring ApplicationSet skips CRDs and uses ServerSideApply to avoid annotation size limits:

```yaml
syncOptions:
  - CreateNamespace=true
  - ServerSideApply=true
  - SkipDryRunOnMissingResource=true
```

## DNS Management (Cloudflare Terraform)

DNS records managed in `terraform-homelab/cloudflare/main.tf`, not external-dns:

```hcl
# Tunnel CNAME (proxied through Cloudflare)
resource "cloudflare_dns_record" "echo_server" {
  zone_id = data.sops_file.cloudflare.data["zone_id"]
  name    = "echo-server"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

# LAN service (not proxied, points to Cilium LB IP)
resource "cloudflare_dns_record" "argocd" {
  zone_id = data.sops_file.cloudflare.data["zone_id"]
  name    = "argocd"
  content = "192.168.0.242"
  type    = "A"
  proxied = false
}
```

Cloudflare API token stored in SOPS: `secrets/hosts/homelab/cloudflare.yaml`

## Storage Pattern

Single-node clusters use hostPath. All data under `/var/data/`:

```
/var/data/
├── configs/          # Per-app config directories
│   ├── plex/
│   ├── sonarr/
│   ├── radarr/
│   ├── prowlarr/
│   ├── overseerr/
│   └── transmission/
├── media/
│   ├── tv/
│   └── movies/
└── torrents/
    ├── complete/
    └── incomplete/
```

Volume mount pattern:
```yaml
volumes:
  - name: config
    hostPath:
      path: /var/data/configs/my-app
      type: DirectoryOrCreate
```

**No PV/PVC needed** for single-node. Simpler than provisioners.

## k9s (Terminal UI)

TUI for cluster management. Installed via NixOS/home-manager.

```bash
k9s                        # default context
k9s -n <namespace>         # specific namespace
k9s --context <ctx>        # specific cluster

# Key bindings
:pods / :svc / :deploy     # switch resource view
/pattern                   # filter
d                          # describe
l                          # logs
s                          # shell
ctrl-d                     # delete
```
