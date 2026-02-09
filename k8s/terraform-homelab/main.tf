terraform {
  required_version = ">= 1.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.48"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
    sops = {
      source  = "carlpett/sops"
      version = ">= 1.0"
    }
  }
}

provider "helm" {
  kubernetes = {
    config_path = "/etc/rancher/k3s/k3s.yaml"
  }
}

provider "kubectl" {
  config_path = "/etc/rancher/k3s/k3s.yaml"
}

provider "sops" {}

data "sops_file" "cloudflare" {
  source_file = "../../secrets/hosts/homelab/cloudflare.yaml"
}

provider "cloudflare" {
  api_token = data.sops_file.cloudflare.data["api_token"]
}

module "cilium" {
  source = "./helm-cilium"
}

module "cilium_l2" {
  source = "./helm-cilium-l2"

  depends_on = [module.cilium]
}

module "argocd" {
  source = "./argocd"

  depends_on = [module.cilium_l2]
}

module "cloudflare" {
  source = "./cloudflare"

  cloudflare_zone_id   = data.sops_file.cloudflare.data["zone_id"]
  cloudflare_tunnel_id = var.cloudflare_tunnel_id
}

module "applicationset" {
  source = "./applicationset"

  depends_on = [module.argocd]
}
