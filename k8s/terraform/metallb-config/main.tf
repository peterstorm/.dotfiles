terraform {
  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.7.0"
    }
  }
}

 /* resource "null_resource" "set_strict_arp" {
   triggers = {
     always_run = "${timestamp()}"
   }

   provisioner "local-exec" {
     command = "kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e 's/strictARP: false/strictARP: true/' | kubectl apply -f - -n kube-system"
   }

   provisioner "local-exec" {
     when    = destroy
     command = "kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e 's/strictARP: true/strictARP: false/' | kubectl apply -f - -n kube-system"
   }
 }
*/

resource "kubectl_manifest" "metallb-config-crds" {
  yaml_body = file("./metallb-config/metallb-config-crds.yaml")

  depends_on = [helm_release.metallb]
}

resource "helm_release" "metallb" {
  name = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  namespace = "metallb-system"
  create_namespace = true
  version = "0.13.12"

  values = [file("./metallb-config/metallb.yaml")]

  # depends_on = [null_resource.set_strict_arp]

}
