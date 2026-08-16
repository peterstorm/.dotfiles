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

Every hostname below is a public DNS name, but they fall into two groups that
differ in *who can route to the answer*. The distinction is the security model,
so it is worth keeping straight.

### Public — proxied tunnel CNAMEs, reachable by anyone

These resolve to Cloudflare anycast and are served over the tunnel. There is no
Cloudflare Access application on this zone, so **these are open to the internet**.
A tunnel is transport, not authorization.

| Service | URL |
|---------|-----|
| Echo Server | https://echo-server.peterstorm.io |
| dotslash.dev | https://dotslash.dev |

### Private — unproxied A records in RFC1918 space

These resolve to `192.168.0.x`, which nobody on the internet can route to. That
makes the address itself the authorization boundary: no Access policy is needed
because there is no public path to protect. They work from two places —

1. **On the LAN**, directly.
2. **From anywhere, via WARP**, using the `192.168.0.0/24` private network route
   declared in `terraform-homelab/cloudflare/main.tf`. Requires the device to be
   enrolled in the Zero Trust org; enrollment is the gate.

| Service | URL | Host |
|---------|-----|------|
| ArgoCD | https://argocd.peterstorm.io | Cilium ingress `192.168.0.242` |
| Grafana | https://grafana.peterstorm.io | Cilium ingress `192.168.0.242` |
| Sonarr | https://sonarr.peterstorm.io | Cilium ingress `192.168.0.242` |
| Radarr | https://radarr.peterstorm.io | Cilium ingress `192.168.0.242` |
| Prowlarr | https://prowlarr.peterstorm.io | Cilium ingress `192.168.0.242` |
| Overseerr | https://overseerr.peterstorm.io | Cilium ingress `192.168.0.242` |
| Transmission | https://transmission.peterstorm.io | Cilium ingress `192.168.0.242` |
| Plex | http://plex.peterstorm.io:32400 | dedicated LB `192.168.0.241` |
| vLLM inference | http://vllm.peterstorm.io:8000 | `desktop` `192.168.0.80` |
| Inference stats heatmap | http://vllm-stats.peterstorm.io:8090 | `desktop` `192.168.0.80` |

### Access-gated — proxied CNAME behind a Cloudflare Access policy

Reachable from anywhere, but only with credentials. Cloudflare's edge rejects
unauthenticated requests before they touch the tunnel.

| Service | Hostname | Origin | Policy |
|---------|----------|--------|--------|
| vLLM inference (TCP) | `vllm-tcp.peterstorm.io` | `tcp://192.168.0.80:8000` | `non_identity` service token |

## Reaching the LAN from a machine that cannot route it

### Why layer 3 does not work here

A host running a full-tunnel corporate VPN cannot reach the private group even on
the home network. Cisco Secure Client installs its own `192.168.0.0/24` route on
its `utun` interface — same prefix length as the directly-connected LAN route, so
specificity does not save you and the tunnel wins. `route -n get 192.168.0.28`
returning a `utun` interface is the confirmation.

Adding a second layer-3 tunnel (WARP, Tailscale) does not fix this. It enters the
same routing-table contest, and on a corporate laptop it usually cannot be
installed at all: those clients ship a launch daemon and a system extension, both
of which need admin rights. Check with `id -Gn | grep -q admin`.

The way out is to stop using the routing table. Both options below are userspace
processes — no route, no interface, no privilege — and both work identically
whether you are at home or on the other side of the world.

### Option A — WARP proxy mode (needs admin, gives raw IP)

Best when you have admin and want arbitrary `IP:port`, not one service at a time.

```sh
warp-cli registration new homelab-k8s
warp-cli mode proxy      # SOCKS5 on 127.0.0.1:40000, installs no routes
warp-cli connect
curl --socks5-hostname 127.0.0.1:40000 http://vllm.peterstorm.io:8000/v1/models
export ALL_PROXY=socks5h://127.0.0.1:40000   # OpenAI SDK / httpx honour this
```

The `h` in `socks5h` matters: DNS resolves at the proxy inside Cloudflare, so a
corporate resolver never sees the query and cannot interfere. Proxy mode is
TCP-only — `ping` failing is expected, not a fault.

Two settings are easy to miss and both fail *silently*, as a hang rather than an
error:

- WARP's default Split Tunnel is **Exclude** mode and the stock exclude list
  contains all of RFC1918, `192.168.0.0/16` included. Switch to Include mode with
  only `192.168.0.0/24`, which also keeps WARP from claiming that range on
  foreign networks that happen to use it.
- The device needs an enrollment policy covering it.

Install the **standalone** WARP client, not the App Store "Cloudflare One Agent"
— the latter ships no `warp-cli`.

### Option B — `cloudflared access tcp` (no admin, per service)

The only option on a locked-down machine, and the one the work Mac uses.
`cloudflared` is a plain binary that opens an outbound HTTPS connection and
listens on loopback. Nothing it does requires privilege.

```sh
vllm-forward            # or `vllm-forward 9000` for a different local port
```

Then, in another shell, any OpenAI-compatible client works with no flags —
`OPENAI_API_KEY` and `OPENAI_BASE_URL` are exported from sops by the darwin role:

```sh
curl -H "Authorization: Bearer $OPENAI_API_KEY" http://localhost:8000/v1/models
```

`vllm-forward` is defined in `roles/home-manager/core-apps/darwin/default.nix`.
It reads the Access service token from a sops template rather than the
environment, so the credential never reaches shell history or scrollback.

Note that `OPENAI_BASE_URL` is exported in *every* shell, not only while the
forward is running. Any OpenAI SDK will honour it, so a tool expecting real
OpenAI will get connection-refused when `vllm-forward` is down.

### Two layers of auth, and why both

| Layer | Answers | Protects against |
|-------|---------|------------------|
| Cloudflare Access service token | may you open a TCP connection | the public internet |
| vLLM `--api-key` | may you use the model | leaked service token, anything already on the LAN |

The unroutable-address trick that protects `vllm.peterstorm.io` buys nothing
against a host already inside the LAN. vLLM's own key is what covers that; it
lives at `~/.config/ds4-flash/api-key` on `desktop`, generated by
`scripts/run-ds4-v20-r33.sh`.

### Setting this up on a new client

1. **Terraform** creates the CNAME, service token, Access application and policy
   (`terraform-homelab/cloudflare/main.tf`). Read the credentials once:
   ```sh
   terraform output -raw vllm_access_client_id
   terraform output -raw vllm_access_client_secret
   ```
2. **sops** — put them plus the vLLM key in the user's secret file:
   ```sh
   sops secrets/users/<user>/cloudflare-access.yaml
   # vllm_client_id / vllm_client_secret / vllm_api_key
   ```
3. **Commit the secret file.** Flakes only see git-tracked files, and sops-nix
   resolves `sopsFile` into the store at *evaluation* time — so an untracked
   secret fails the build with `path ... does not exist` even though it is
   sitting right there on disk.
4. `./hm-apply.sh`, then open a new shell so the exports load.

Rotate the token by tainting `cloudflare_zero_trust_access_service_token.vllm_tcp`
and repeating steps 1–4.

### Diagnosing a failed forward

`cloudflared access tcp` collapses every failure into `websocket: bad handshake`,
because the upgrade either returns 101 or it does not. Probe the same hostname
with plain `curl` to turn that one symptom into a readable status code:

```sh
curl -s -o /dev/null -w "%{http_code}\n" https://vllm-tcp.peterstorm.io/

# and with credentials
. ~/.config/sops-nix/secrets/rendered/cf-access-env
curl -s -I -H "CF-Access-Client-Id: $CF_ACCESS_CLIENT_ID" \
        -H "CF-Access-Client-Secret: $CF_ACCESS_CLIENT_SECRET" \
        https://vllm-tcp.peterstorm.io/
```

| Unauthenticated | With token | Meaning |
|-----------------|------------|---------|
| 403 | 101 / upgrade | working as intended |
| 403 | 403 | token not in the policy, or wrong/stale credentials |
| 403 | **404** | Access fine, but the tunnel has no ingress rule — it fell to the `http_status:404` catch-all. Almost always the ConfigMap reload below |
| 200 | — | **the Access application is not attached; the origin is public** |
| 530 | — | tunnel down; check the cloudflared pod |

A 502 once the rule is live means cloudflared has the route but cannot reach
`192.168.0.80:8000` — `desktop` is off, or vLLM is not listening.

`{"error":"Unauthorized"}` on `localhost:8000` is **vLLM**, not Cloudflare. The
whole path is working and you are missing the `Authorization: Bearer` header.

### ConfigMap changes do not reload cloudflared

Editing the ingress list in `argocd-homelab/cloudflared/configmap.yaml` is not
enough. ArgoCD's contract ends at "the object in etcd matches git" — nothing in
it restarts the process. The kubelet refreshes the projected volume eventually,
but the atomic symlink swap it uses does not reliably fire the inotify event
`cloudflared` watches for.

ArgoCD will show the app **Synced and Healthy** throughout, because the drift is
between the mounted file and the running process — below what ArgoCD observes.

```sh
kubectl get cm cloudflared-config -n cloudflared -o yaml | grep <hostname>
kubectl rollout restart deployment/cloudflared -n cloudflared
```

Anything in this repo pairing a `configmap.yaml` with a long-lived process has
the same failure mode.

## Post-wipe bootstrap gotchas

When deploying on a node that previously ran flannel/kube-proxy (or any prior CNI):

1. **Delete old flannel VXLAN interface** before cilium can initialize:
   ```bash
   sudo ip link delete flannel.1
   ```
   Cilium uses VXLAN on port 8472 — if flannel.1 holds it, cilium's datapath fails
   and all pod creation returns 429 (TooManyRequests).

2. **Flush stale kube-proxy iptables** — k3s with `--disable-kube-proxy` doesn't clean
   up old rules from previous installs. These intercept service traffic before cilium's
   BPF can handle it:
   ```bash
   sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F
   sudo iptables -X && sudo iptables -t nat -X && sudo iptables -t mangle -X
   ```

3. **Restart k3s** after cleaning up to get a fresh state:
   ```bash
   sudo systemctl restart k3s
   ```

4. **Restart all kube-system pods** after cilium is healthy — pods created before
   cilium's datapath was ready have stale network namespaces:
   ```bash
   kubectl rollout restart daemonset cilium cilium-envoy -n kube-system
   kubectl rollout restart deployment cilium-operator coredns hubble-relay hubble-ui metrics-server -n kube-system
   ```

5. **ArgoCD CRDs from previous install** — if old CRDs exist without Helm labels,
   helm install fails. Either delete them first or adopt with:
   ```bash
   kubectl label crd applications.argoproj.io app.kubernetes.io/managed-by=Helm --overwrite
   kubectl annotate crd applications.argoproj.io meta.helm.sh/release-name=argocd meta.helm.sh/release-namespace=argocd --overwrite
   ```

6. **Kubeconfig** — terraform providers must use `/etc/rancher/k3s/k3s.yaml` directly,
   not a stale copy at `~/.kube/config`. k3s rotates certs on restart.

## Local inference monitoring (desktop)

The `monitoring/` app scrapes whichever inference engine owns `desktop:8000/metrics` (currently vLLM or SGLang; see `monitoring/values.yaml` → `prometheusSpec.additionalScrapeConfigs`). `monitoring/templates/inference-recording-rules.yaml` normalizes engine-specific names into a stable `inference:*` contract. The dashboard `monitoring/dashboard-vllm.json` consumes that contract and is auto-provisioned into Grafana via the sidecar ConfigMap (`monitoring/templates/dashboard-vllm.yaml`, label `grafana_dashboard=1`). Raw vLLM fallbacks preserve pre-normalization history.

- Verify scraping: Grafana → Explore → `up{job="vllm-desktop"}` should be 1
- Engine counters reset on container restart or runtime switch; Prometheus `rate()`/`increase()` handle process resets while the durable ledger below preserves lifetime totals
- SGLang DSpark adds acceptance length/rate, verification-rate, and Mamba-state panels; those panels are absent rather than zero for runtimes without those features
- Prefix-cache effectiveness is a rolling five-minute, token-weighted ratio derived from SGLang's monotonic `prefill_effective_tokens_total` counters; do not graph its last-interval `cache_hit_rate` gauge. Idle windows remain gaps rather than false 0% misses, and the `calculation="token_weighted_5m"` label excludes incompatible pre-correction gauge history. KV occupancy and prefix-cache effectiveness are separate panels because lower occupancy and higher hit rate are desirable.
- Storage: PVC on `local-path` (thin-provisioned, claim 10Gi) + `retentionSize: 9GiB (B suffix required by CRD regex)` — Prometheus auto-deletes oldest blocks past 9Gi, so it can never fill the node disk; `retention: 30d`
- Check homelab disk has room to grow (run from a machine that has SSH keys for it, e.g. laptop):
  ```bash
  ssh homelab 'df -h / && du -sh /var/lib/rancher/k3s/storage/* 2>/dev/null | sort -h'
  ```
  If free space is < ~15Gi, drop `storage: 10Gi` → `5Gi` and/or `retentionSize: 9GiB (B suffix required by CRD regex)` → `4Gi` in `monitoring/values.yaml`.

### Lifetime token ledger (survives everything)

Prometheus history dies on cluster wipes, so `desktop` keeps its own append-only ledger: `systemd.timers.vllm-stats-record` (`machines/desktop/default.nix`) runs every 15 min, detects the vLLM or SGLang metric schema and `model_name` at `127.0.0.1:8000/metrics`, and appends one logical token/request-delta row per endpoint/model to `/var/lib/vllm-stats/stats.csv`. Rows include the actual observation interval plus prompt and generation served-throughput averages. The self-contained page at `/var/lib/vllm-stats/heatmap/index.html` provides an all-model/per-model selector, comparison table, 24-hour throughput chart, activity calendar, and durable totals. Historical five-column rows migrate atomically to an honest `Historical aggregate` bucket because their model identity cannot be reconstructed. Per-endpoint/model baselines survive partial outages, and a pending-interval journal commits every model row and its new counter state without loss or duplication. Scripts: `scripts/vllm-stats-record.py`, `scripts/vllm-stats-heatmap.py`.

- Activate on desktop: commit the new `scripts/` files (flake requires tracked files), then `nixos-rebuild switch --flake .#desktop` + `sudo systemctl start vllm-stats-record.timer` (first run only seeds the baseline)
- Serving: `systemd.services.vllm-stats-http` serves the heatmap dir on :8090 (firewall-opened). DNS: `vllm-stats.peterstorm.io` is an unproxied A record → `192.168.0.80` (`terraform-homelab/cloudflare/main.tf`), so it is reachable on the LAN and via WARP but not from the internet. It was formerly a proxied tunnel CNAME, which published the heatmap publicly. LAN: http://192.168.0.80:8090 direct.
- View the heatmap: `scp desktop:/var/lib/vllm-stats/heatmap/index.html .` and open it, or serve the dir
- Quick re-run: `sudo systemctl start vllm-stats-record.service` (logs to journald)

### Adding another model or runtime

The Grafana contract keys off `model_name` after normalizing runtime-specific metrics. A new model in the **same engine schema** needs nothing. A new engine on the existing exclusive port needs one mapping in `inference-recording-rules.yaml` and `COUNTER_SCHEMAS` in `vllm-stats-record.py`. A **separate concurrent endpoint on a new port** additionally needs:

1. A launch script (mirror `scripts/run-ds4-v20-r33.sh`, different `PORT` + `SERVED_MODEL_NAME`)
2. Firewall: add the port to `networking.firewall.allowedTCPPorts` in `machines/desktop/default.nix`
3. Ledger: add the URL to `VLLM_METRICS_URLS` (whitespace-separated) in `systemd.services.vllm-stats-record` — per-endpoint baselines means a restart of one container never disturbs the other's accounting; the new endpoint seeds its baseline on the next run
4. Prometheus: add a `- targets: ["192.168.0.80:8001"]` static target in `monitoring/values.yaml` → `additionalScrapeConfigs`
5. Grafana: add the new raw metric family to the model-variable fallback only if its normalized recording rule can be delayed during rollout
6. pi: add a provider/model entry in `pi/models.json`

## Troubleshooting

```bash
# App not syncing
kubectl -n argocd get app <app-name> -o yaml | grep -A5 status

# ksops decryption failing
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-repo-server | grep -i sops

# Cloudflared not connecting
kubectl -n cloudflared logs -l app=cloudflared

# Ingress rule edited in git but a hostname still 404s: the pod is running the
# old config. ArgoCD syncs the ConfigMap without restarting the process, and
# shows Synced/Healthy the whole time. See "ConfigMap changes do not reload
# cloudflared" above.
kubectl get cm cloudflared-config -n cloudflared -o yaml | grep <hostname>
kubectl rollout restart deployment/cloudflared -n cloudflared

# Pod stuck
kubectl -n <namespace> describe pod -l app=<app>

# Cilium issues
kubectl -n kube-system exec ds/cilium -- cilium status

# Cilium service routing broken (pods can't reach ClusterIP services)
kubectl exec -n kube-system ds/cilium -- cilium service list  # check for (maintenance) backends
kubectl exec -n kube-system ds/cilium -- cilium-health status  # check endpoint reachability
sudo iptables -t nat -L KUBE-SERVICES | head  # stale kube-proxy rules?

# Cilium VXLAN conflict
kubectl logs -n kube-system ds/cilium | grep "address already in use"  # flannel.1 blocking port 8472
ip link show flannel.1  # if exists, delete it
```

## Architecture

```
terraform-homelab/     # Bootstrap: Cilium, ArgoCD, DNS, ApplicationSet
  helm-cilium/         # Cilium helm release (prefixed to avoid chart name collision)
  helm-cilium-l2/      # Cilium L2 announcement + IP pool
  argocd/              # ArgoCD helm release
  applicationset/      # Root ApplicationSet (git directory generator)
  cloudflare/          # DNS records via Cloudflare provider
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
