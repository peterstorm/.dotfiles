terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.48"
    }
  }
}

variable "cloudflare_zone_id" {
  type = string
}

variable "cloudflare_tunnel_id" {
  type = string
}

# Services via Cloudflare tunnel (proxied)
locals {
  tunnel_services = [
    "echo-server",
    "argocd",
    "grafana",
    "sonarr",
    "radarr",
    "prowlarr",
    "overseerr",
    "transmission",
  ]
}

resource "cloudflare_dns_record" "tunnel" {
  for_each = toset(local.tunnel_services)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
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
