resource "helm_release" "ingress" {
  name = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx/"
  chart      = "ingress-nginx"
  namespace = "ingress-nginx"
  create_namespace = true
  version = "4.8.3"
}
