provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

module "metallb" {
  source = "./metallb-config"
}

module "ingress" {
  source = "./ingress"

  depends_on = [module.metallb]
}

module "argocd" {
  source = "./argocd"

  depends_on = [module.metallb]
}
