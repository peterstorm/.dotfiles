resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  # Pinned: 1.19.8 fixes the FnSetRetval CGroupSock feature-probe crash on
  # kernel 7.2.8 (cilium/cilium#48376); 1.19.3 crash-loops the agent after the
  # 2026-10-02 reboot. Unpin once on a release line that handles this.
  version    = "1.19.8"
  namespace  = "kube-system"

  values = [file("${path.module}/values.yaml")]
}
