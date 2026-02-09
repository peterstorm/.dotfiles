# argocd-homelab Apps

Each subdirectory is auto-discovered by the root ApplicationSet and becomes an ArgoCD Application.
Namespace = directory name.

## Adding a new app

1. Create directory: `k8s/argocd-homelab/<app-name>/`
2. Add `kustomization.yaml` (or `Chart.yaml` for helm)
3. Add manifests
4. If secrets needed: add `secret-generator.yaml` + `secrets.enc.yaml` (ksops pattern)
5. Commit + push — ArgoCD auto-syncs

## Secrets (ksops pattern)

```bash
# Create plaintext secret
cat > secrets.enc.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
type: Opaque
stringData:
  key: value
EOF

# Encrypt
sops -e -i secrets.enc.yaml

# Reference in kustomization.yaml
# generators:
#   - secret-generator.yaml
```

## Apps

| App | Type | Secrets | Storage |
|-----|------|---------|---------|
| cloudflared | kustomize + ksops | tunnel credentials | none |
| echo-server | kustomize | none | none |
| plex | kustomize | none | /var/data/configs/plex, /var/data/media |
| transmission | kustomize + ksops | openvpn credentials | /var/data/configs/transmission, /var/data/torrents, /var/data/media |
| sonarr | kustomize | none | /var/data/configs/sonarr, /var/data/media, /var/data/torrents |
| radarr | kustomize | none | /var/data/configs/radarr, /var/data/media, /var/data/torrents |
| prowlarr | kustomize | none | /var/data/configs/prowlarr |
| overseerr | kustomize | none | /var/data/configs/overseerr |
| monitoring | helm (Chart.yaml) | none | emptyDir (ephemeral) |

## Storage

All hostPath on `/var/data/`. Single-node cluster, no PV/PVC needed.

```
/var/data/
├── configs/{plex,sonarr,radarr,prowlarr,overseerr,transmission}/
├── media/{tv,movies}/
└── torrents/{complete,incomplete}/
```

Directories auto-created by `DirectoryOrCreate` in Deployment specs.
