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

# echo-server via Cloudflare tunnel (proxied)
resource "cloudflare_dns_record" "echo_server" {
  zone_id = var.cloudflare_zone_id
  name    = "echo-server"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

# Services on shared LB IP (not proxied, local DNS)
locals {
  shared_lb_services = [
    "sonarr",
    "radarr",
    "prowlarr",
    "overseerr",
    "transmission",
    "grafana",
    "argocd",
  ]
}

resource "cloudflare_dns_record" "shared_lb" {
  for_each = toset(local.shared_lb_services)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "192.168.0.240"
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
