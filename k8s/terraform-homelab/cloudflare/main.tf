terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = ">= 5.0"
    }
  }
}

variable "cloudflare_zone_id" {
  type = string
}

variable "cloudflare_tunnel_id" {
  type = string
}

# echo-server via Cloudflare tunnel (external access)
resource "cloudflare_dns_record" "echo_server" {
  zone_id = var.cloudflare_zone_id
  name    = "echo-server"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# Services on Cilium ingress LB IP (LAN only, not proxied)
locals {
  lan_services = [
    "argocd",
    "grafana",
    "sonarr",
    "radarr",
    "prowlarr",
    "overseerr",
    "transmission",
  ]
}

resource "cloudflare_dns_record" "lan" {
  for_each = toset(local.lan_services)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "192.168.0.242"
  type    = "A"
  proxied = false
  ttl     = 1
}

# Plex on dedicated LB IP (not proxied)
resource "cloudflare_dns_record" "plex" {
  zone_id = var.cloudflare_zone_id
  name    = "plex"
  content = "192.168.0.241"
  type    = "A"
  proxied = false
  ttl     = 1
}
