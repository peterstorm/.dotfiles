terraform {
  required_version = ">= 1.0"

  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.12"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

provider "kubectl" {
  config_path = "~/.kube/config"
}

provider "cloudflare" {
  # uses CLOUDFLARE_API_TOKEN env var
}

module "cilium" {
  source = "./cilium"
}

module "cilium_l2" {
  source = "./cilium-l2"

  depends_on = [module.cilium]
}

module "argocd" {
  source = "./argocd"

  depends_on = [module.cilium_l2]
}

module "cloudflare" {
  source = "./cloudflare"

  cloudflare_zone_id   = var.cloudflare_zone_id
  cloudflare_tunnel_id = var.cloudflare_tunnel_id
}

module "applicationset" {
  source = "./applicationset"

  depends_on = [module.argocd]
}
