terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
  }
}

resource "kubectl_manifest" "cloudflare_api_token_secret" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "cloudflare-api-token"
      namespace = "cert-manager"
    }
    type = "Opaque"
    stringData = {
      api-token = var.cloudflare_api_token
    }
  })
}

resource "kubectl_manifest" "letsencrypt_prod" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        email  = "peterstorm@gmail.com"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = "cloudflare-api-token"
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })

  depends_on = [kubectl_manifest.cloudflare_api_token_secret]
}
