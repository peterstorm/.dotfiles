terraform {
  required_version = ">= 0.13"

  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
  }
}

resource "kubectl_manifest" "ipaddresspool" {
  yaml_body = file("./metallb-config/metallb-ipaddresspool.yaml")

  depends_on = [helm_release.metallb]
}

resource "kubectl_manifest" "l2advertisement" {
  yaml_body = file("./metallb-config/metallb-l2advertisement.yaml")

  depends_on = [kubectl_manifest.ipaddresspool]
}

resource "helm_release" "metallb" {
  name = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  namespace = "metallb-system"
  create_namespace = true
  version = "0.13.12"

  # values = [file("./metallb-config/metallb.yaml")]

  # depends_on = [null_resource.set_strict_arp]

}
