resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  # Pinned: unpinned it stayed on whatever chart the state recorded at first
  # apply (v1.19.3 for months). 1.19.3 is inside the affected range of
  # CVE-2026-62290 (>= 1.18.0, <= 1.20.2): a Direct ACME Challenge resource can
  # bypass the Issuer DNS01 solver policy and spend the ClusterIssuer's
  # Cloudflare DNS credentials — which is exactly what letsencrypt-prod holds.
  version          = "v1.21.2"
  namespace        = "cert-manager"
  create_namespace = true

  values = [yamlencode({
    crds = {
      enabled = true
    }
  })]
}
