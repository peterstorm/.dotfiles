# Hetzner Dedicated Server: NixOS + K3s + GitOps

## Overview

Install NixOS on Hetzner dedicated server via nixos-anywhere, bootstrap k3s cluster with Terraform, hand off to ArgoCD.

**Stack:**
- NixOS via nixos-anywhere (RAID1, no LUKS)
- K3s (single node, local-path-provisioner)
- Cilium (CNI + kube-proxy replacement)
- Cloudflare Tunnel (sole ingress, multi-domain, zero open ports)
- Cloudflare Access (email OTP for restricted services)
- ArgoCD + ksops (GitOps with SOPS-encrypted secrets in git)
- Terraform (Cloudflare DNS/tunnel + cluster bootstrap only)
- sops-nix (host secrets) + ksops (k8s secrets via ArgoCD)

**Removed from original plan (and why):**
- ~~cert-manager~~ — Cloudflare terminates TLS at edge, tunnel is encrypted
- ~~external-dns~~ — DNS managed via Terraform `cloudflare_record`, external-dns can't create tunnel CNAMEs and would actively break routing
- ~~Gateway API for external traffic~~ — cloudflared routes directly to ClusterIP services, no LoadBalancer needed
- ~~LUKS~~ — not needed for this use case

---

## Architecture: How Multi-Domain Tunnel Routing Works

```
┌──────────────────────────────────────────────────────────────────┐
│ CLOUDFLARE EDGE                                                  │
│                                                                  │
│  client1.com ──┐                                                 │
│  client2.dk ───┤── DNS CNAMEs to <TUNNEL_ID>.cfargotunnel.com   │
│  app.mysite.io─┤                                                 │
│  argocd.mysite.io┘                                               │
│                         ▼                                        │
│               ┌─────────────────┐                                │
│               │ Cloudflare TLS  │  ← terminates TLS here         │
│               │ + Access policy │  ← email OTP for restricted    │
│               └────────┬────────┘                                │
│                        │ encrypted tunnel (outbound from server) │
└────────────────────────┼─────────────────────────────────────────┘
                         │
┌────────────────────────┼─────────────────────────────────────────┐
│ HETZNER SERVER         ▼                                         │
│               ┌─────────────────┐                                │
│               │  cloudflared    │                                 │
│               │  (ingress rules)│                                 │
│               └────────┬────────┘                                │
│                        │ hostname-based routing:                  │
│                        │                                         │
│  client1.com ─────────► svc/client1-nginx.websites:80            │
│  client2.dk  ─────────► svc/client2-nginx.websites:80            │
│  app.mysite.io ──────► svc/my-app.default:3000                   │
│  argocd.mysite.io ───► svc/argocd-server.argocd:80               │
│  ssh.mysite.io ──────► ssh://localhost:22                        │
│  * (catch-all) ──────► http_status:404                           │
└──────────────────────────────────────────────────────────────────┘
```

**Key points:**
- One tunnel serves unlimited domains — ingress rules do hostname routing
- Per-client domains: add to Cloudflare account (free plan), CNAME to tunnel
- Your own domain: wildcard CNAME `*.mysite.io → tunnel` catches all subdomains
- No ports open on server — cloudflared makes outbound connections only
- SSH access through tunnel via `cloudflared access ssh`

---

## Phase 0: Pre-flight (local machine)

### 0.1 Generate age keypair for hetzner host

```bash
age-keygen -o hetzner.key
# Output: public key: age1xxxxxx...
# Save public key for .sops.yaml
# NEVER commit hetzner.key to git
```

### 0.2 Update .sops.yaml

```yaml
keys:
  - &hetzner age1xxxxxx...  # public key from 0.1

creation_rules:
  - path_regex: secrets/hosts/hetzner/.*
    key_groups:
      - age:
          - *peterstorm
          - *hetzner
```

### 0.3 Cloudflare Tunnel — handled by Terraform

The tunnel is created by Terraform in Phase 3.6 — **no manual `cloudflared` CLI needed.**

Terraform will:
1. Generate a random tunnel secret
2. Create the tunnel via Cloudflare API
3. Construct the credentials JSON from the tunnel outputs
4. Create the k8s Secret with the credentials
5. Create DNS CNAME records pointing to the tunnel

All you need in SOPS is your Cloudflare API token and account/zone IDs.

### 0.4 Prepare SOPS secret file

**File:** `secrets/hosts/hetzner/k8s-secrets.yaml`

```yaml
cloudflare_api_token: "xxx"           # Permissions: Zone:DNS:Edit, Zone:Zone:Read
cloudflare_zone_id: "xxx"             # Your primary domain's zone ID
cloudflare_account_id: "xxx"          # Cloudflare account ID
argocd_repo_ssh_key: |                # Deploy key for private git repo (if repo is private)
  -----BEGIN OPENSSH PRIVATE KEY-----
  ...
  -----END OPENSSH PRIVATE KEY-----
```

> **Where to find these values:**
> - `cloudflare_api_token`: Cloudflare dashboard → My Profile → API Tokens → Create Token
>   - Permissions: Zone:DNS:Edit, Zone:Zone:Read
>   - Zone Resources: Include → Specific zone → yourdomain.com
> - `cloudflare_zone_id`: Cloudflare dashboard → yourdomain.com → Overview → right sidebar → Zone ID
> - `cloudflare_account_id`: Cloudflare dashboard → any site → Overview → right sidebar → Account ID
> - `argocd_repo_ssh_key`: `ssh-keygen -t ed25519 -f argocd-deploy-key` → add `.pub` as deploy key in GitHub repo settings

### 0.5 Re-encrypt secrets with new hetzner key

```bash
sops updatekeys secrets/hosts/hetzner/k8s-secrets.yaml
```

---

## Phase 1: NixOS Configuration

### 1.1 Create machine config

**Directory:**
```
machines/hetzner/
├── default.nix      # hardware-configuration
└── disko.nix        # declarative disk partitioning (RAID1)
```

**`machines/hetzner/default.nix`** — hardware config (template, adjust after checking rescue system):

```nix
# machines/hetzner/default.nix
# Generated from rescue system inspection. Adjust values after running:
#   ssh root@HETZNER_IP "lscpu && lsblk && ip link show"
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
    ./disko.nix
  ];

  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.systemd-boot.enable = true;

  # Hetzner dedicated servers typically use Intel NICs
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "nvme" "sd_mod"     # storage
    "e1000e" "igb" "ixgbe"                  # Intel NICs (common on Hetzner)
  ];
  boot.kernelModules = [ "kvm-intel" ];     # or kvm-amd, check CPU

  # mdadm RAID monitoring
  boot.swraid = {
    enable = true;
    mdadmConf = "MAILADDR root";
  };

  # Sync ESP from primary to fallback disk daily
  systemd.services.sync-esp = {
    description = "Mirror ESP to fallback disk";
    script = ''
      ${pkgs.rsync}/bin/rsync -a --delete /boot/ /boot-fallback/
    '';
    serviceConfig.Type = "oneshot";
  };
  systemd.timers.sync-esp = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
```

> **Note:** After booting rescue system, run `lscpu`, `lsblk`, `ip link show` to get actual
> CPU type (Intel/AMD), disk device paths (sda/sdb vs nvme0n1/nvme1n1), and NIC name.
> Update this file accordingly.

### 1.2 Disko config — RAID1 with mirrored ESP

Both disks get an ESP partition so the system can boot from either disk if one fails.

```nix
# machines/hetzner/disko.nix
{
  disko.devices = {
    disk = {
      sda = {
        type = "disk";
        device = "/dev/sda";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            mdraid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "raid1";
              };
            };
          };
        };
      };
      sdb = {
        type = "disk";
        device = "/dev/sdb";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot-fallback";  # mounted but not primary
              };
            };
            mdraid = {
              size = "100%";
              content = {
                type = "mdraid";
                name = "raid1";
              };
            };
          };
        };
      };
    };
    mdadm = {
      raid1 = {
        type = "mdadm";
        level = 1;
        content = {
          type = "filesystem";
          format = "ext4";
          mountpoint = "/";
        };
      };
    };
  };
}
```

**Post-install:** Add sdb ESP to UEFI boot order in Hetzner BIOS.
The ESP sync timer is defined in `machines/hetzner/default.nix` (see 1.1) and runs daily via systemd.

### 1.3 K3s + Cilium role

```nix
# roles/k3s-cilium/default.nix
{ pkgs, ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = toString [
      "--flannel-backend=none"
      "--disable-kube-proxy"           # Required for Cilium kubeProxyReplacement
      "--disable=servicelb"
      "--disable=traefik"
      "--disable-network-policy"       # Cilium handles this
      "--write-kubeconfig-mode=644"
      "--cluster-cidr=10.42.0.0/16"    # Explicit, must match Cilium
      "--service-cidr=10.43.0.0/16"    # Explicit, must match Cilium
    ];
    # local-path-provisioner enabled (NOT in --disable list)
  };

  # Kernel modules required by Cilium
  boot.kernelModules = [
    "br_netfilter"
    "ip_tables"
    "ip6_tables"
    "xt_conntrack"
    "xt_mark"
    "veth"
  ];

  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = 1;
    "net.ipv6.conf.all.forwarding" = 1;
    "net.ipv4.conf.all.rp_filter" = 0;  # Required for Cilium BPF
  };

  # Firewall: SSH only, everything else through tunnel
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    # All k8s traffic is internal (single node, Cilium eBPF bypasses nftables)
    # Web traffic enters via cloudflared (outbound tunnel, no inbound ports)
  };

  # Swap safety valve (OOM on single-node = full outage)
  zramSwap = {
    enable = true;
    memoryPercent = 25;
  };
}
```

### 1.4 Add host to flake.nix

```nix
hetzner = host.mkHost {
  name = "hetzner";
  roles = [ "core" "efi" "ssh" "k3s-cilium" ];
  machine = [ "hetzner" ];
  NICs = [ "enp0s31f6" ];  # CHECK in rescue system: `ip link show`
  cpuCores = 8;            # Adjust to actual
  users = [
    { name = "peterstorm"; groups = [ "wheel" ]; uid = 1000; hashedPasswordFile = ...; shell = pkgs.zsh; }
  ];
};
```

### 1.5 SOPS setup for hetzner

```yaml
# .sops.yaml — add hetzner age key (done in Phase 0)
keys:
  - &hetzner age1xxxxxx...

creation_rules:
  - path_regex: secrets/hosts/hetzner/.*
    key_groups:
      - age:
          - *peterstorm
          - *hetzner
```

---

## Phase 2: nixos-anywhere Installation

### 2.1 Prerequisites

1. Hetzner server in rescue mode (Linux rescue system)
2. SSH access to rescue system: `ssh root@<HETZNER_IP>`
3. Age private key ready at `extra-files/var/lib/sops-nix/keys.txt`
4. Check NIC name: `ip link show` in rescue system → update `flake.nix`
5. Check disk devices: `lsblk` in rescue system → update `disko.nix`

### 2.2 Prepare extra-files

```bash
mkdir -p extra-files/var/lib/sops-nix
cp hetzner.key extra-files/var/lib/sops-nix/keys.txt
chmod 600 extra-files/var/lib/sops-nix/keys.txt
```

### 2.3 Run nixos-anywhere

```bash
#!/usr/bin/env bash
set -euo pipefail

HETZNER_IP="${1:?Usage: $0 <hetzner-ip>}"

nix run github:nix-community/nixos-anywhere -- \
  --flake .#hetzner \
  --target-host root@$HETZNER_IP \
  --extra-files ./extra-files
```

Note: no `--disk-encryption-keys` (no LUKS).

### 2.4 Verify installation

```bash
ssh root@$HETZNER_IP "nixos-version"     # Should return NixOS version
ssh root@$HETZNER_IP "systemctl is-active k3s"  # Should return "active"
ssh root@$HETZNER_IP "cat /proc/mdstat"  # Should show RAID1 active
```

---

## Phase 3: Terraform Bootstrap

### 3.1 Directory structure

```
k8s/terraform-hetzner/
├── main.tf              # providers
├── versions.tf          # provider version pins
├── variables.tf         # input variables
├── terraform.tfvars     # actual values (git-ignored!)
├── secrets.tf           # sops → k8s secrets
├── cilium.tf            # Cilium CNI + wait resource
├── cloudflare.tf        # tunnel + DNS records
├── cloudflare-access.tf # Access policies for restricted services
├── argocd.tf            # ArgoCD bootstrap
└── values/
    ├── cilium.yaml      # Cilium Helm values
    └── argocd.yaml      # ArgoCD Helm values
```

### 3.2 Provider setup

```hcl
# main.tf
terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    helm       = { source = "hashicorp/helm" }
    kubectl    = { source = "alekc/kubectl" }
    sops       = { source = "carlpett/sops" }
    cloudflare = { source = "cloudflare/cloudflare" }
    random     = { source = "hashicorp/random" }
  }
}

provider "sops" {}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

provider "kubectl" {
  config_path = var.kubeconfig_path
}

provider "cloudflare" {
  api_token = data.sops_file.k8s_secrets.data["cloudflare_api_token"]
}
```

```hcl
# versions.tf
terraform {
  required_version = ">= 1.5"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.48"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

```hcl
# variables.tf
variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/hetzner.yaml"
}

variable "primary_domain" {
  description = "Primary domain for services"
  type        = string
  # e.g. "mysite.io"
}

variable "admin_email" {
  description = "Email for Cloudflare Access OTP"
  type        = string
}

variable "sops_age_key_path" {
  description = "Path to age private key for ksops (ArgoCD SOPS decryption)"
  type        = string
  # e.g. "/path/to/hetzner.key" — NEVER commit this file
}
```

**`terraform.tfvars`** (example, git-ignored):

```hcl
# terraform.tfvars — DO NOT commit (add to .gitignore)
primary_domain    = "yourdomain.com"
admin_email       = "you@yourdomain.com"
kubeconfig_path   = "~/.kube/hetzner.yaml"
sops_age_key_path = "../../hetzner.key"  # relative to terraform-hetzner/
```

> **Important:** Add `terraform.tfvars` to `.gitignore`. The SOPS-encrypted secrets are safe
> to commit, but `terraform.tfvars` contains the path to your private age key.

### 3.3 SOPS secrets → k8s secrets

```hcl
# secrets.tf

# --- Read SOPS-encrypted secrets ---
data "sops_file" "k8s_secrets" {
  source_file = "../../secrets/hosts/hetzner/k8s-secrets.yaml"
}

# --- Namespaces (depend on Cilium being ready) ---
resource "kubernetes_namespace" "cloudflared" {
  metadata { name = "cloudflared" }
  depends_on = [null_resource.wait_for_cilium]
}

resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
  depends_on = [null_resource.wait_for_cilium]
}

# --- Cloudflared tunnel credentials ---
# Constructed from Terraform's tunnel resource (Phase 3.6), NOT from SOPS.
# The tunnel secret + ID + account ID are combined into the JSON format
# that cloudflared expects at /etc/cloudflared/credentials.json
resource "kubernetes_secret" "cloudflared_credentials" {
  metadata {
    name      = "cloudflared-credentials"
    namespace = "cloudflared"
  }
  data = {
    "credentials.json" = jsonencode({
      AccountTag   = data.sops_file.k8s_secrets.data["cloudflare_account_id"]
      TunnelID     = cloudflare_tunnel.hetzner.id
      TunnelSecret = random_id.tunnel_secret.b64_std
    })
  }
  depends_on = [kubernetes_namespace.cloudflared]
}

# --- ArgoCD repo deploy key ---
resource "kubernetes_secret" "argocd_repo_key" {
  metadata {
    name      = "argocd-repo-key"
    namespace = "argocd"
  }
  data = {
    sshPrivateKey = data.sops_file.k8s_secrets.data["argocd_repo_ssh_key"]
    type          = "git"
    url           = "git@github.com:peterstorm/dotfiles"
  }
  depends_on = [kubernetes_namespace.argocd]
}

# --- Age key for ksops (ArgoCD decrypts SOPS secrets in git) ---
resource "kubernetes_secret" "sops_age_key" {
  metadata {
    name      = "sops-age-key"
    namespace = "argocd"
  }
  data = {
    keys.txt = file(var.sops_age_key_path)  # path to hetzner.key
  }
  depends_on = [kubernetes_namespace.argocd]
}
```

> **Credentials flow explained:**
> 1. `random_id.tunnel_secret` generates a random 32-byte secret
> 2. `cloudflare_tunnel.hetzner` creates the tunnel using that secret
> 3. `kubernetes_secret.cloudflared_credentials` constructs the JSON cloudflared needs:
>    ```json
>    {"AccountTag":"<account_id>","TunnelID":"<tunnel_id>","TunnelSecret":"<base64_secret>"}
>    ```
> 4. The cloudflared Deployment mounts this secret at `/etc/cloudflared/credentials.json`
> 5. No manual `cloudflared tunnel create` needed — it's all Terraform-managed

### 3.4 Cilium

```hcl
# cilium.tf
resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = "1.16.5"

  values = [file("${path.module}/values/cilium.yaml")]

  wait    = true
  timeout = 600
}

# Wait for Cilium + CoreDNS to be ready before deploying anything else
resource "null_resource" "wait_for_cilium" {
  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG=${var.kubeconfig_path}
      echo "Waiting for Cilium agent..."
      kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cilium-agent \
        -n kube-system --timeout=300s
      echo "Waiting for CoreDNS..."
      kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns \
        -n kube-system --timeout=180s
      echo "Waiting for node Ready..."
      kubectl wait --for=condition=Ready node --all --timeout=120s
      echo "Cluster ready."
    EOT
  }
  depends_on = [helm_release.cilium]
}
```

**values/cilium.yaml:**
```yaml
operator:
  replicas: 1

ipam:
  mode: kubernetes

kubeProxyReplacement: true
k8sServiceHost: "127.0.0.1"
k8sServicePort: "6443"

hubble:
  relay:
    enabled: true
  ui:
    enabled: true
```

### 3.5 Deployment order

```
1. Cilium (CNI — cluster non-functional without it)
   ↓
2. null_resource: wait for Cilium + CoreDNS + node Ready
   ↓
3. Namespaces + K8s secrets (cloudflared creds, ArgoCD repo key, ksops age key)
   ↓
4. ArgoCD helm release
   ↓
5. app-of-apps manifest (ArgoCD takes over from here)

ArgoCD then deploys (via sync waves):
   wave 0: cloudflared
   wave 1: HTTPRoutes / app configs
   wave 2: application workloads
```

### 3.6 Cloudflare resources (tunnel + DNS)

```hcl
# cloudflare.tf

# --- Tunnel ---
resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_tunnel" "hetzner" {
  account_id = data.sops_file.k8s_secrets.data["cloudflare_account_id"]
  name       = "hetzner-prod"
  secret     = random_id.tunnel_secret.b64_std
}

# --- DNS records ---

# Wildcard for primary domain (catches all subdomains)
resource "cloudflare_record" "wildcard" {
  zone_id = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name    = "*"
  content = "${cloudflare_tunnel.hetzner.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true  # Must be proxied for tunnel to work
}

# Root domain
resource "cloudflare_record" "root" {
  zone_id = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name    = "@"
  content = "${cloudflare_tunnel.hetzner.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}

# Client domains — add one block per client domain
# (these domains must be added to your Cloudflare account first)
#
# resource "cloudflare_record" "client1" {
#   zone_id = "client1_zone_id"
#   name    = "@"
#   content = "${cloudflare_tunnel.hetzner.id}.cfargotunnel.com"
#   type    = "CNAME"
#   proxied = true
# }
```

### 3.7 Cloudflare Access (restricted services)

```hcl
# cloudflare-access.tf

# ArgoCD — email OTP (no static IP dependency)
resource "cloudflare_access_application" "argocd" {
  zone_id          = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name             = "ArgoCD Hetzner"
  domain           = "argocd.${var.primary_domain}"
  session_duration = "24h"
  type             = "self_hosted"
}

resource "cloudflare_access_policy" "argocd_email_otp" {
  application_id = cloudflare_access_application.argocd.id
  zone_id        = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name           = "Email OTP"
  precedence     = 1
  decision       = "allow"

  include {
    email = [var.admin_email]
  }
}

# Hubble UI — same pattern
resource "cloudflare_access_application" "hubble" {
  zone_id          = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name             = "Hubble UI"
  domain           = "hubble.${var.primary_domain}"
  session_duration = "24h"
  type             = "self_hosted"
}

resource "cloudflare_access_policy" "hubble_email_otp" {
  application_id = cloudflare_access_application.hubble.id
  zone_id        = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name           = "Email OTP"
  precedence     = 1
  decision       = "allow"

  include {
    email = [var.admin_email]
  }
}

# SSH access — through tunnel, protected by Access
resource "cloudflare_access_application" "ssh" {
  zone_id          = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name             = "SSH Hetzner"
  domain           = "ssh.${var.primary_domain}"
  session_duration = "730h"  # 30 days, SSH sessions are already authenticated
  type             = "ssh"
}

resource "cloudflare_access_policy" "ssh_email_otp" {
  application_id = cloudflare_access_application.ssh.id
  zone_id        = data.sops_file.k8s_secrets.data["cloudflare_zone_id"]
  name           = "Email OTP"
  precedence     = 1
  decision       = "allow"

  include {
    email = [var.admin_email]
  }
}
```

### 3.8 ArgoCD bootstrap

```hcl
# argocd.tf
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = false  # namespace created in secrets.tf
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "7.7.10"

  values = [file("${path.module}/values/argocd.yaml")]

  depends_on = [
    null_resource.wait_for_cilium,
    kubernetes_secret.argocd_repo_key,
    kubernetes_secret.sops_age_key,
  ]
}

# Bootstrap app-of-apps — single source of truth in argocd-hetzner/
resource "kubectl_manifest" "app_of_apps" {
  yaml_body = file("${path.module}/../argocd-hetzner/app-of-apps.yaml")

  depends_on = [helm_release.argocd]
}
```

**values/argocd.yaml:**

> **Bug fixed:** The original had duplicate `volumes`/`volumeMounts` keys under `repoServer`.
> In YAML, duplicate keys silently overwrite — second wins, first is lost.
> Below merges both into single lists.

```yaml
server:
  # Cloudflare Tunnel terminates TLS — ArgoCD runs insecure
  extraArgs:
    - --insecure

repoServer:
  # --- Volumes (single list, both ksops tools + age key) ---
  volumes:
    - name: sops-age-key
      secret:
        secretName: sops-age-key
    - name: custom-tools
      emptyDir: {}

  # --- Volume mounts (single list) ---
  volumeMounts:
    - name: sops-age-key
      mountPath: /home/argocd/.config/sops/age
      readOnly: true
    - name: custom-tools
      mountPath: /usr/local/bin/ksops
      subPath: ksops
    - name: custom-tools
      mountPath: /usr/local/bin/kustomize
      subPath: kustomize

  env:
    - name: SOPS_AGE_KEY_FILE
      value: /home/argocd/.config/sops/age/keys.txt
    - name: XDG_CONFIG_HOME
      value: /home/argocd/.config

  # Init container: copy ksops + kustomize binaries into shared emptyDir
  initContainers:
    - name: install-ksops
      image: viaductoss/ksops:v4.3.2
      command: ["/bin/sh", "-c"]
      args:
        - echo "Installing KSOPS...";
          cp /usr/local/bin/ksops /custom-tools/;
          cp /usr/local/bin/kustomize /custom-tools/;
          echo "Done.";
      volumeMounts:
        - mountPath: /custom-tools
          name: custom-tools

configs:
  # Repository credentials
  repositories:
    dotfiles:
      url: git@github.com:peterstorm/dotfiles
      sshPrivateKeySecret:
        name: argocd-repo-key
        key: sshPrivateKey

  rbac:
    policy.default: role:readonly

  params:
    # Track by annotation to avoid fights with Terraform-created resources
    application.resourceTrackingMethod: annotation
```

---

## Phase 4: ArgoCD Handoff

### 4.1 ArgoCD application structure

```
k8s/argocd-hetzner/
├── app-of-apps.yaml               # Root application (bootstrapped by Terraform)
├── apps/                           # Application manifests
│   ├── cloudflared.yaml            # sync wave 0
│   └── your-apps/...              # sync wave 2+
├── cloudflared/
│   ├── kustomization.yaml
│   ├── deployment.yaml
│   ├── configmap.yaml              # ingress rules
│   └── secrets.yaml                # ksops-encrypted, references SOPS file
└── websites/
    ├── client1/
    │   ├── deployment.yaml
    │   └── service.yaml
    └── client2/
        ├── deployment.yaml
        └── service.yaml
```

### 4.2 app-of-apps.yaml

```yaml
# k8s/argocd-hetzner/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:peterstorm/dotfiles
    targetRevision: main
    path: k8s/argocd-hetzner/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: false   # Safety: don't auto-delete apps
      selfHeal: true
```

### 4.3 Cloudflared ArgoCD application

```yaml
# k8s/argocd-hetzner/apps/cloudflared.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cloudflared
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Deploy first
    argocd.argoproj.io/sync-options: Prune=false  # Never auto-delete tunnel
spec:
  project: default
  source:
    repoURL: git@github.com:peterstorm/dotfiles
    targetRevision: main
    path: k8s/argocd-hetzner/cloudflared
  destination:
    server: https://kubernetes.default.svc
    namespace: cloudflared
  syncPolicy:
    automated:
      selfHeal: true
```

### 4.4 Cloudflared manifests (managed by ArgoCD)

All files in `k8s/argocd-hetzner/cloudflared/`:

**kustomization.yaml:**
```yaml
# k8s/argocd-hetzner/cloudflared/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: cloudflared

resources:
  - deployment.yaml
  - configmap.yaml
```

**configmap.yaml** — tunnel ingress rules:
```yaml
# k8s/argocd-hetzner/cloudflared/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cloudflared-config
  namespace: cloudflared
data:
  config.yaml: |
    tunnel: hetzner-prod
    credentials-file: /etc/cloudflared/credentials.json
    no-autoupdate: true
    metrics: 0.0.0.0:2000
    ingress:
      # --- Restricted services (protected by CF Access) ---
      - hostname: argocd.yourdomain.com
        service: http://argocd-server.argocd:80
      - hostname: hubble.yourdomain.com
        service: http://hubble-ui.kube-system:80
      - hostname: ssh.yourdomain.com
        service: ssh://localhost:22

      # --- Client websites ---
      - hostname: client1.com
        service: http://client1-nginx.websites:80
      - hostname: www.client1.com
        service: http://client1-nginx.websites:80
      - hostname: client2.dk
        service: http://client2-nginx.websites:80

      # --- Your apps ---
      - hostname: app.yourdomain.com
        service: http://my-app.default:3000

      # --- Catch-all (MUST be last) ---
      - service: http_status:404
```

**deployment.yaml** — cloudflared pod:
```yaml
# k8s/argocd-hetzner/cloudflared/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  namespace: cloudflared
  labels:
    app: cloudflared
spec:
  replicas: 1  # Single node, one replica sufficient
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      containers:
        - name: cloudflared
          image: cloudflare/cloudflared:2024.12.2  # Pin version
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config.yaml
            - run
          ports:
            - name: metrics
              containerPort: 2000
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 10
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: 2000
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config.yaml
              subPath: config.yaml
              readOnly: true
            - name: credentials
              mountPath: /etc/cloudflared/credentials.json
              subPath: credentials.json
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: credentials
          secret:
            secretName: cloudflared-credentials
            # This secret is created by Terraform in secrets.tf
            # It contains the tunnel credentials JSON
```

> **Note:** The `cloudflared-credentials` secret is created by Terraform during bootstrap (Phase 3.3).
> ArgoCD will see it already exists and not try to manage it. This is intentional —
> Terraform owns bootstrap secrets, ArgoCD owns application manifests.

### 4.5 ksops: How encrypted secrets work in ArgoCD

For any ArgoCD-managed app that needs secrets from SOPS, here's the pattern.
This example shows how a hypothetical app would reference encrypted secrets:

**Directory structure for an app with secrets:**
```
k8s/argocd-hetzner/my-app/
├── kustomization.yaml        # references the ksops generator
├── deployment.yaml
├── service.yaml
├── secret-generator.yaml     # ksops generator pointing to encrypted file
└── secrets.enc.yaml          # SOPS-encrypted secret (safe to commit)
```

**secrets.enc.yaml** — encrypted with SOPS (safe in git):
```yaml
# Created with: sops -e -i secrets.enc.yaml
# Uses the age key from .sops.yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secrets
  namespace: default
type: Opaque
stringData:
  DATABASE_URL: ENC[AES256_GCM,data:xxxx...,type:str]
  API_KEY: ENC[AES256_GCM,data:xxxx...,type:str]
sops:
  kms: []
  gcp_kms: []
  azure_kv: []
  hc_vault: []
  age:
    - recipient: age1xxxxxx...
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
        -----END AGE ENCRYPTED FILE-----
  lastmodified: "2024-01-01T00:00:00Z"
  mac: ENC[AES256_GCM,data:xxxx...,type:str]
  version: 3.9.0
```

**secret-generator.yaml** — tells ksops to decrypt:
```yaml
# k8s/argocd-hetzner/my-app/secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: my-app-secrets-generator
  annotations:
    config.kubernetes.io/function: |
      exec:
        path: ksops
files:
  - ./secrets.enc.yaml
```

**kustomization.yaml** — wires it together:
```yaml
# k8s/argocd-hetzner/my-app/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

generators:
  - secret-generator.yaml  # ksops decrypts at sync time

resources:
  - deployment.yaml
  - service.yaml
```

**How it works end-to-end:**
1. You encrypt secrets locally: `sops -e -i secrets.enc.yaml`
2. Commit encrypted file to git (safe — it's AES256 encrypted)
3. ArgoCD syncs the app, sees the ksops generator in kustomization.yaml
4. ArgoCD's repo-server has the age key (mounted from Terraform bootstrap secret)
5. ksops decrypts the secret at sync time, applies the plaintext Secret to k8s
6. Your app reads the Secret as normal env vars / volume mounts

**Creating a new encrypted secret:**
```bash
# Create plaintext secret YAML
cat > secrets.enc.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secrets
  namespace: default
type: Opaque
stringData:
  DATABASE_URL: "postgres://user:pass@host/db"
  API_KEY: "sk-xxx"
EOF

# Encrypt in-place with SOPS
sops -e -i --age age1xxxxxx... secrets.enc.yaml

# Commit (encrypted, safe)
git add secrets.enc.yaml && git commit -m "add my-app secrets"
```

### 4.6 Adding a new client website

1. Add domain to Cloudflare account (free plan)
2. Add Terraform `cloudflare_record` CNAME → tunnel
3. Add ingress rule to cloudflared configmap
4. Add k8s deployment + service in `k8s/argocd-hetzner/websites/clientN/`
5. Commit → ArgoCD auto-syncs

---

## Phase 5: Bootstrap Script

**File:** `scripts/bootstrap-hetzner-k8s.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

HETZNER_IP="${1:?Usage: $0 <hetzner-ip>}"
KUBECONFIG_PATH="$HOME/.kube/hetzner.yaml"

echo "=== Phase 1: Verify NixOS ==="
ssh root@$HETZNER_IP "nixos-version"
ssh root@$HETZNER_IP "systemctl is-active k3s"

echo "=== Phase 2: SSH tunnel for kubectl ==="
# Open SSH tunnel — kubectl talks to 127.0.0.1:6443, tunneled to server
# No need to expose port 6443 publicly
ssh -f -N -L 6443:127.0.0.1:6443 root@$HETZNER_IP
echo "SSH tunnel open on localhost:6443"

echo "=== Phase 3: Fetch kubeconfig ==="
scp root@$HETZNER_IP:/etc/rancher/k3s/k3s.yaml "$KUBECONFIG_PATH"
# Keep 127.0.0.1 — we're using SSH tunnel, no sed needed
export KUBECONFIG="$KUBECONFIG_PATH"

echo "=== Phase 4: Wait for k3s API ==="
until kubectl get nodes &>/dev/null; do
  echo "  waiting for API server..."
  sleep 5
done
echo "API server responding (node will be NotReady until Cilium is installed)"

echo "=== Phase 5: Terraform ==="
cd k8s/terraform-hetzner
terraform init
terraform apply -auto-approve
cd -

echo "=== Phase 6: Verify cluster ==="
echo "--- Cilium ---"
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=cilium-agent \
  -n kube-system --timeout=300s

echo "--- Node ---"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo "--- ArgoCD ---"
kubectl -n argocd wait --for=condition=Ready pod -l app.kubernetes.io/name=argocd-server \
  --timeout=300s
kubectl -n argocd get applications

echo "--- Cloudflared (may take a minute for ArgoCD to sync) ---"
sleep 30
kubectl -n cloudflared get pods

echo "=== Done! ==="
echo "ArgoCD UI: https://argocd.yourdomain.com (protected by CF Access)"
echo "Admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo ""
echo "SSH tunnel is still running. Kill it when done:"
echo "  kill \$(lsof -ti:6443)"
echo ""
echo "Future kubectl access via cloudflared:"
echo "  ssh -o ProxyCommand='cloudflared access ssh --hostname ssh.yourdomain.com' root@ssh.yourdomain.com"
```

---

## Post-Bootstrap: Day-to-Day Operations

### SSH via Cloudflare Tunnel (server-side setup)

The cloudflared ingress already routes `ssh.yourdomain.com → ssh://localhost:22`.
Cloudflare Access protects it with email OTP. Two things needed:

**1. Server-side: install `cloudflared` on NixOS for short-lived certs (optional but recommended):**

Add to your k3s-cilium role or a separate ssh role:

```nix
# Optional: cloudflared for SSH short-lived certificates
# This lets Cloudflare Access issue short-lived SSH certs instead of key-based auth
# For now, regular SSH key auth through the tunnel works fine.
# Add this later if you want to eliminate SSH keys entirely.
```

**2. Client-side: configure SSH to use the tunnel:**

```bash
# One-time: add to ~/.ssh/config
Host hetzner
  HostName ssh.yourdomain.com
  User root
  ProxyCommand cloudflared access ssh --hostname %h
```

**How it works:**
1. You run `ssh hetzner`
2. `cloudflared access ssh` opens a browser for Cloudflare Access email OTP
3. After OTP verification, the SSH connection tunnels through Cloudflare
4. No ports open on the server — traffic goes: your machine → Cloudflare edge → tunnel → cloudflared pod → SSH on localhost
5. The session stays authenticated for the Access session duration (730h for SSH)

**kubectl access day-to-day:**
```bash
# Option 1: SSH tunnel through cloudflared (recommended)
ssh -L 6443:127.0.0.1:6443 hetzner -N &
export KUBECONFIG=~/.kube/hetzner.yaml
kubectl get nodes

# Option 2: Direct SSH + kubectl on server
ssh hetzner "kubectl get nodes"
```

### Adding a new domain/website

Step-by-step for onboarding a new client:

```bash
# 1. Add domain to Cloudflare (via dashboard or CLI)
#    - Add site in Cloudflare dashboard → select Free plan
#    - Update domain's nameservers to Cloudflare's at the registrar
#    - Wait for DNS propagation (can take up to 24h)

# 2. Add Terraform DNS record (in cloudflare.tf)
#    resource "cloudflare_record" "client_newclient" {
#      zone_id = "newclient_zone_id_from_cloudflare"
#      name    = "@"
#      content = "${cloudflare_tunnel.hetzner.id}.cfargotunnel.com"
#      type    = "CNAME"
#      proxied = true
#    }
#    # Also add www if needed
#    resource "cloudflare_record" "client_newclient_www" {
#      zone_id = "newclient_zone_id_from_cloudflare"
#      name    = "www"
#      content = "${cloudflare_tunnel.hetzner.id}.cfargotunnel.com"
#      type    = "CNAME"
#      proxied = true
#    }

# 3. Apply Terraform
cd k8s/terraform-hetzner && terraform apply

# 4. Add cloudflared ingress rule (in cloudflared/configmap.yaml)
#    - hostname: newclient.com
#      service: http://newclient-nginx.websites:80
#    - hostname: www.newclient.com
#      service: http://newclient-nginx.websites:80

# 5. Add k8s manifests (in argocd-hetzner/websites/newclient/)
#    - deployment.yaml (nginx serving static site, or whatever)
#    - service.yaml (ClusterIP pointing to the deployment)

# 6. Commit and push → ArgoCD auto-syncs
git add -A && git commit -m "add newclient.com" && git push
```

### NixOS updates

```bash
# From dotfiles repo, through cloudflared tunnel:
nixos-rebuild switch --flake .#hetzner --target-host root@hetzner

# Or SSH in and rebuild locally on the server:
ssh hetzner
cd /etc/nixos  # or wherever you keep the flake
git pull && nixos-rebuild switch --flake .#hetzner
```

### Troubleshooting cheat sheet

```bash
# --- Tunnel not working ---
kubectl -n cloudflared logs -l app=cloudflared         # Check tunnel logs
kubectl -n cloudflared get pods                         # Is the pod running?
kubectl -n cloudflared describe pod -l app=cloudflared  # Events/errors?

# --- ArgoCD not syncing ---
kubectl -n argocd get applications                     # Sync status
kubectl -n argocd logs -l app.kubernetes.io/name=argocd-repo-server  # Repo/ksops errors

# --- Cilium issues ---
kubectl -n kube-system exec ds/cilium -- cilium status # Cilium health
kubectl -n kube-system exec ds/cilium -- cilium connectivity test  # Full test

# --- DNS not resolving ---
kubectl run tmp-debug --image=busybox --rm -it -- nslookup kubernetes.default
# If this fails, CoreDNS is broken

# --- Node not Ready ---
kubectl describe node  # Look at Conditions section
kubectl -n kube-system get pods  # Are Cilium + CoreDNS running?

# --- Emergency: can't reach through tunnel ---
# Fall back to direct SSH (port 22 is open in firewall)
ssh root@<HETZNER_IP>  # Use the raw IP
kubectl get pods -A     # Debug from the server
```

---

## File Summary

### New files to create

```
machines/hetzner/
├── default.nix              # Hardware config (adjust after rescue inspection)
└── disko.nix                # RAID1 + mirrored ESP

roles/k3s-cilium/
└── default.nix              # k3s flags + Cilium kernel modules + firewall

secrets/hosts/hetzner/
└── k8s-secrets.yaml         # SOPS-encrypted (CF token, tunnel creds, ArgoCD key)

k8s/terraform-hetzner/
├── main.tf                  # Provider configs
├── versions.tf              # Provider version pins
├── variables.tf             # Input variables (kubeconfig, domain, email, age key path)
├── terraform.tfvars         # Actual values (git-ignored!)
├── .gitignore               # terraform.tfvars, *.tfstate, .terraform/
├── secrets.tf               # SOPS → k8s secrets (cloudflared creds, ArgoCD key, age key)
├── cilium.tf                # Cilium helm + wait-for-ready null_resource
├── cloudflare.tf            # Tunnel creation + DNS CNAME records
├── cloudflare-access.tf     # Access apps + email OTP policies
├── argocd.tf                # ArgoCD helm + app-of-apps kubectl_manifest
└── values/
    ├── cilium.yaml          # kubeProxyReplacement, k8sServiceHost, hubble
    └── argocd.yaml          # --insecure, ksops init container, repo creds

k8s/argocd-hetzner/
├── app-of-apps.yaml         # Root Application (bootstrapped by Terraform)
├── apps/
│   └── cloudflared.yaml     # ArgoCD Application (sync wave 0, Prune=false)
├── cloudflared/
│   ├── kustomization.yaml   # References deployment + configmap
│   ├── deployment.yaml      # cloudflared pod with health checks + resource limits
│   └── configmap.yaml       # Tunnel ingress rules (hostname → service routing)
└── websites/
    └── clientN/             # Per-client: deployment.yaml + service.yaml
        ├── deployment.yaml
        └── service.yaml

scripts/
├── install-hetzner.sh       # nixos-anywhere wrapper
└── bootstrap-hetzner-k8s.sh # SSH tunnel + kubeconfig + terraform + verify

extra-files/                  # Temporary, used during nixos-anywhere install only
└── var/lib/sops-nix/
    └── keys.txt             # Age private key (NEVER commit)
```

### Files to modify

- `flake.nix` — add hetzner host definition
- `.sops.yaml` — add hetzner age public key + creation rule
- `.gitignore` — add `k8s/terraform-hetzner/terraform.tfvars`, `hetzner.key`, `extra-files/`

---

## Verification Checklist

1. **NixOS installed**: `ssh root@<ip> "nixos-version"` → NixOS
2. **RAID1 healthy**: `ssh root@<ip> "cat /proc/mdstat"` → `[UU]` (both disks active)
3. **k3s running**: `kubectl get nodes` → shows Ready
4. **Cilium healthy**: `kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-agent` → Running
5. **CoreDNS running**: `kubectl -n kube-system get pods -l k8s-app=kube-dns` → Running
6. **Cloudflared connected**: `kubectl -n cloudflared logs -l app=cloudflared` → "Connection registered"
7. **ArgoCD synced**: `kubectl -n argocd get app app-of-apps` → Synced/Healthy
8. **Tunnel working**: `curl https://argocd.yourdomain.com` → CF Access login page
9. **SSH via tunnel**: `ssh -o ProxyCommand='cloudflared access ssh --hostname ssh.yourdomain.com' root@ssh.yourdomain.com`

---

## Resolved Questions

- **Disk layout**: RAID1 + ext4, mirrored ESP on both disks, no LUKS
- **Tunnel**: Terraform-managed `hetzner-prod`, sole ingress path
- **TLS**: Cloudflare terminates at edge, no cert-manager needed
- **DNS**: Terraform `cloudflare_record` per domain, no external-dns
- **Restricted access**: Cloudflare Access with email OTP (no static IP needed)
- **Storage**: local-path-provisioner (k3s default)
- **Secrets in k8s**: ksops plugin in ArgoCD, age key mounted from bootstrap secret
- **kubectl access**: SSH tunnel during bootstrap, `cloudflared access ssh` day-to-day
- **LoadBalancer**: Not needed — cloudflared routes to ClusterIP services directly

## Unresolved Questions

1. **Hetzner NIC name**: check rescue system `ip link show`
2. **Hetzner disk devices**: check `lsblk` — may be nvme not sda/sdb
3. **Primary domain**: which domain for infra services?
4. **Git repo**: is `peterstorm/dotfiles` the right repo, or separate infra repo?
5. **ArgoCD ksops version**: verify compat with ArgoCD chart version 7.7.10
6. **Cilium version**: 1.16.5 pinned — check latest stable when implementing
