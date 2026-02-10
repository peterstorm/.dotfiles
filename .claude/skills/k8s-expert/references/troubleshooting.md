# Kubernetes Troubleshooting Guide

Extended debugging workflows for the K3s + Cilium + ksops stack.

## Pod Lifecycle Issues

### CrashLoopBackOff

```bash
kubectl describe pod <pod> -n <ns> | grep -A 5 "Last State"
kubectl logs <pod> -n <ns> --previous

# Check if OOMKilled
kubectl get pod <pod> -n <ns> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'

# Common causes:
# - Missing environment variables or config
# - Failed liveness/readiness probes
# - Application error on startup
# - OOMKilled (increase memory limits)
```

### ImagePullBackOff

```bash
kubectl describe pod <pod> -n <ns> | grep Image

# Private registry — verify imagePullSecrets
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.imagePullSecrets}'

# Create docker registry secret
kubectl create secret docker-registry regcred \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<password> \
  -n <ns>
```

### Pending — Scheduling Issues

```bash
kubectl describe nodes | grep -A 5 "Allocated resources"
kubectl get pod <pod> -n <ns> -o yaml | grep -A 10 nodeSelector
kubectl describe nodes | grep Taints
```

## Cilium Networking Issues

### Cilium Not Ready

```bash
# Check overall status
cilium status

# Agent logs (most common issue source)
kubectl logs -n kube-system -l k8s-app=cilium --tail=200

# Operator logs
kubectl logs -n kube-system -l name=cilium-operator --tail=100

# Check Cilium pods
kubectl get pods -n kube-system -l k8s-app=cilium

# Common causes:
# - K3s started with flannel still enabled
# - Stale flannel.1 interface: sudo ip link delete flannel.1
# - Old kube-proxy iptables rules not flushed
# - Cilium CRDs not installed (Helm failure)
```

### L2 Load Balancer Not Working

```bash
# Check if services have EXTERNAL-IP
kubectl get svc -A | grep LoadBalancer

# Verify IP pool exists and has capacity
kubectl get ciliumbgppeeringpolicies,ciliumloadbalancerippool -A

# Check L2 announcement policy
kubectl get ciliuml2announcementpolicy -A -o yaml

# Verify ARP responses
arping -I <interface> <lb-ip>

# Check Cilium agent for L2 errors
kubectl logs -n kube-system -l k8s-app=cilium | grep -i "l2\|announce"

# Common causes:
# - CiliumLoadBalancerIPPool not applied (CRDs not ready during bootstrap)
# - IP range conflicts with DHCP
# - L2 announcement policy missing
```

### Pod-to-Pod / Pod-to-Service Connectivity

```bash
# Full connectivity test
cilium connectivity test

# Check endpoints (should match pod count)
kubectl get ciliumendpoints -n <ns>

# Live traffic observation
hubble observe -n <ns>
hubble observe --verdict DROPPED       # find dropped packets
hubble observe --to-service <svc>      # traffic to specific service

# DNS resolution test
kubectl run dns-test --rm -it --image=busybox -- nslookup <svc>.<ns>.svc.cluster.local

# Service endpoint check
kubectl get endpoints <svc> -n <ns>
```

### Ingress Not Working (Cilium)

```bash
# Check ingress status
kubectl get ingress -n <ns>
kubectl describe ingress <name> -n <ns>

# Verify Cilium ingress controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium-envoy

# Check Cilium envoy config
kubectl logs -n kube-system -l app.kubernetes.io/name=cilium-envoy --tail=50

# Verify ingressClassName is "cilium"
kubectl get ingress <name> -n <ns> -o jsonpath='{.spec.ingressClassName}'

# Check TLS certificate
kubectl get certificate -n <ns>
kubectl describe certificate <name> -n <ns>

# Common causes:
# - ingressClassName not set or wrong (must be "cilium")
# - cert-manager certificate not ready
# - Service/port mismatch in ingress rules
```

## ksops / SOPS Secrets Issues

### Secret Not Decrypted

```bash
# Check ArgoCD app sync status
argocd app get <app>

# Check repo-server logs for ksops errors
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --tail=100 | grep -i "sops\|ksops\|decrypt\|age"

# Verify age key secret exists
kubectl get secret sops-age-key -n argocd

# Verify age key content (should have keys.txt)
kubectl get secret sops-age-key -n argocd -o jsonpath='{.data}' | jq 'keys'

# Test manual decryption on host
sops -d k8s/argocd-homelab/<app>/secrets.enc.yaml

# Common causes:
# - sops-age-key secret missing (k3s-sops-age-key-sync service failed)
# - secrets.enc.yaml not encrypted with correct age key
# - ksops binary not mounted in repo-server
# - secret-generator.yaml path wrong
```

### Age Key Sync Failed

```bash
# Check systemd service on NixOS host
systemctl status k3s-sops-age-key-sync
journalctl -u k3s-sops-age-key-sync

# Manual sync
kubectl create secret generic sops-age-key \
  --from-file=keys.txt=/var/lib/sops-nix/keys.txt \
  -n argocd --dry-run=client -o yaml | kubectl apply -f -

# Verify
kubectl get secret sops-age-key -n argocd
```

### Re-Encrypting Secrets

```bash
# Update keys (when age key rotated or .sops.yaml changed)
sops updatekeys k8s/argocd-homelab/<app>/secrets.enc.yaml

# Edit encrypted file
sops k8s/argocd-homelab/<app>/secrets.enc.yaml

# Encrypt new file
sops -e -i secrets.yaml
```

## K3s Issues

### K3s Not Starting

```bash
# Check service status
systemctl status k3s
journalctl -u k3s --no-pager -n 100

# Common issues after reinstall:
# 1. Stale flannel interface
sudo ip link delete flannel.1

# 2. Stale kube-proxy iptables
sudo iptables-save | grep -v KUBE | sudo iptables-restore

# 3. Restart K3s
sudo systemctl restart k3s
```

### Kubeconfig Issues

```bash
# K3s kubeconfig location
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Certs rotate on k3s restart — always use original file, don't copy
# The kubeconfig has mode 644 (set by --write-kubeconfig-mode=644)
```

## Certificate Issues

### Cert-Manager Troubleshooting

```bash
# Certificate chain: Certificate → CertificateRequest → Order → Challenge
kubectl get certificates -A
kubectl describe certificate <name> -n <ns>

kubectl get certificaterequests -n <ns>
kubectl describe certificaterequest <name> -n <ns>

kubectl get orders -n <ns>
kubectl describe order <name> -n <ns>

kubectl get challenges -n <ns>
kubectl describe challenge <name> -n <ns>

# Cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager --tail=100
```

### DNS01 Challenge Failing

```bash
# Check Cloudflare API token permissions
# Needs: Zone:Read + DNS:Edit

# Check challenge status
kubectl describe challenge <name> -n <ns>

# Verify cert-manager can reach Cloudflare
kubectl logs -n cert-manager -l app=cert-manager | grep -i "cloudflare\|challenge\|error"

# Verify cloudflare-api-token secret exists in cert-manager namespace
kubectl get secret cloudflare-api-token -n cert-manager
```

## ArgoCD Issues

### Sync Failures

```bash
argocd app get <app>
argocd app sync <app> --dry-run

# Check for resource conflicts
kubectl get events -n <ns> --field-selector reason=FailedCreate

# Force sync (careful)
argocd app sync <app> --force
```

### OutOfSync but No Changes

```bash
argocd app diff <app>

# Common causes:
# - Resource modified outside GitOps (kubectl edit)
# - Defaulted fields added by admission controllers
# - Helm includes dynamic values

# Hard refresh
argocd app get <app> --hard-refresh
```

### ApplicationSet Not Creating Apps

```bash
# Check ApplicationSet controller logs
kubectl logs -n argocd -l app.kubernetes.io/component=applicationset-controller --tail=100

# Verify git directory generator path
# Should match: k8s/argocd-homelab/*

# Check for goTemplate errors (missingkey=error is strict)
```

### ksops Plugin Not Working in ArgoCD

```bash
# Verify custom tools mounted in repo-server
kubectl exec -n argocd -l app.kubernetes.io/component=repo-server -- ls -la /usr/local/bin/ksops

# Verify kustomize build options
kubectl get configmap argocd-cm -n argocd -o yaml | grep kustomize

# Should include: --enable-alpha-plugins --enable-exec
```

## Storage Issues

### hostPath Not Writable

```bash
# Check host directory permissions
ls -la /var/data/configs/<app>/

# Verify volume mount type
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.volumes}' | jq

# DirectoryOrCreate should auto-create, but check parent dir exists
ls -la /var/data/
```

## Resource Issues

### OOMKilled

```bash
kubectl top pods -n <ns>
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].resources.limits}'
```

### CPU Throttling

```bash
kubectl top pods -n <ns>
kubectl get pod <pod> -n <ns> -o jsonpath='{.spec.containers[*].resources.limits.cpu}'
```

## Quick Debug Commands

```bash
# Everything in one namespace
kubectl get all,cm,secret,ingress,certificate -n <ns>

# Recent events
kubectl get events -n <ns> --sort-by='.lastTimestamp' | tail -20

# All pods not Running
kubectl get pods -A | grep -v Running

# Resource usage
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -20

# Cilium quick health
cilium status --brief

# ArgoCD app status
argocd app list
```
