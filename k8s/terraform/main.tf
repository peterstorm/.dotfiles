provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

module "metallb" {
  source = "./metallb-config"
}

module "argocd" {
  source = "./argocd"

  depends_on = [module.metallb]
}
