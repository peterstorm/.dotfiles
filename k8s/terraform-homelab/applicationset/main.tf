terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
  }
}

resource "kubectl_manifest" "root_applicationset" {
  yaml_body = file("${path.module}/appset.yaml")
}
