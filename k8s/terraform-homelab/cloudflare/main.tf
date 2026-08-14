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

variable "cloudflare_dotslash_zone_id" {
  type = string
}

variable "cloudflare_tunnel_id" {
  type = string
}

variable "cloudflare_account_id" {
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

# dotslash.dev via Cloudflare tunnel (external access)
resource "cloudflare_dns_record" "dotslash_dev" {
  zone_id = var.cloudflare_dotslash_zone_id
  name    = "@"
  content = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "dotslash_dev_www" {
  zone_id = var.cloudflare_dotslash_zone_id
  name    = "www"
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

# Services on `desktop` (the AI workstation, 192.168.0.80).
#
# These are deliberately unproxied A records pointing at RFC1918 space, which
# makes them unreachable from the public internet — an address nobody can route
# to needs no Access policy to protect it. They resolve for everyone but only
# *work* for clients that can route 192.168.0.0/24: LAN hosts directly, and
# WARP-enrolled devices via the private network route below.
#
# This replaces the previous proxied tunnel CNAME for vllm-stats, which exposed
# the heatmap to the whole internet (the tunnel is transport, not authorization
# — there is no Access application on this zone). The old comment about error
# 81054 applied to having an A record *alongside* the CNAME; with the CNAME gone
# the conflict does too.
locals {
  desktop_services = [
    "vllm",       # OpenAI-compatible inference API, :8000
    "vllm-stats", # heatmap + raw stats.csv, :8090
  ]
}

resource "cloudflare_dns_record" "desktop" {
  for_each = toset(local.desktop_services)

  zone_id = var.cloudflare_zone_id
  name    = each.key
  content = "192.168.0.80"
  type    = "A"
  proxied = false
  ttl     = 1
}

# Private network route: teaches Cloudflare that 192.168.0.0/24 lives behind
# this tunnel, so WARP-enrolled devices can reach LAN IPs directly. Without it
# `warp-routing.enabled` in the cloudflared configmap is inert — that flag only
# says the tunnel is *willing* to carry WARP traffic, not where the LAN is.
#
# This previously existed only as hand-made state in the Zero Trust dashboard;
# declaring it here ends that drift. /24 rather than a /32 so the Cilium ingress
# (.242) and Plex (.241) are reachable the same way.
resource "cloudflare_zero_trust_tunnel_cloudflared_route" "homelab_lan" {
  account_id = var.cloudflare_account_id
  tunnel_id  = var.cloudflare_tunnel_id
  network    = "192.168.0.0/24"
  comment    = "Homelab LAN — WARP private network access"
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
