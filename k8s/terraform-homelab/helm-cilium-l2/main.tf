terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

resource "time_sleep" "wait_for_cilium_crds" {
  create_duration = "30s"
}

resource "kubectl_manifest" "ip_pool" {
  yaml_body = file("${path.module}/ip-pool.yaml")

  depends_on = [time_sleep.wait_for_cilium_crds]
}

resource "kubectl_manifest" "l2_policy" {
  yaml_body = file("${path.module}/l2-policy.yaml")

  depends_on = [time_sleep.wait_for_cilium_crds]
}
