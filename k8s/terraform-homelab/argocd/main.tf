resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  # Pinned deliberately: without it this floats to whatever chart the state
  # recorded at first apply and silently rots (it sat on 9.4.1 / ArgoCD 3.3.0
  # for months). 10.10.5 ships Argo CD v3.5.5, which is past the 3.5.4 fixes
  # for CVE-2026-113709 / -113708 / -113672 / -77459 (critical repo-server
  # code execution) and CVE-2026-55797 / -45737.
  version          = "10.10.5"
  namespace        = "argocd"
  create_namespace = true

  values = [file("${path.module}/values.yaml")]
}
