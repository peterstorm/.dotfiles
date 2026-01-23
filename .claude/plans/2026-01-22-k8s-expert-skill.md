# Plan: Create k8s-expert Skill

## Context

Create comprehensive Kubernetes expert skill covering:
- Full k8s stack: ArgoCD, Helm, kubectl, networking, secrets, debugging
- Homelab patterns from `k8s/` folder (k3s, ArgoCD GitOps, Terraform)

## Task Breakdown

### Wave 1: Creation
- [x] T1: Create k8s-expert skill with full-stack coverage

### Wave 2: Verification (parallel)
- [x] T2: Review skill structure via skill-reviewer
- [x] T3: Review content quality via content-reviewer

## Execution Order

| ID | Task | Agent | Wave | Depends |
|----|------|-------|------|---------|
| T1 | Create k8s-expert skill | plugin-dev:skill-development | 1 | - |
| T2 | Review skill structure | plugin-dev:skill-reviewer | 2 | T1 |
| T3 | Review content quality | skill-content-reviewer | 2 | T1 |

## Skill Scope

### Topics to Cover
1. **kubectl** - common commands, debugging, logs, exec
2. **Helm** - chart management, values, upgrades, rollbacks
3. **ArgoCD** - GitOps patterns, app-of-apps, sync strategies
4. **Networking** - services, ingress, cert-manager, external-secrets
5. **Debugging** - pod issues, resource constraints, events, describe
6. **Homelab specifics** - k3s setup, terraform patterns from this repo

### Trigger Phrases
- "kubernetes", "k8s", "kubectl", "helm", "argocd"
- "deploy to cluster", "pod issues", "service not working"
- "ingress config", "cert-manager", "external-secrets"

## Verification Checklist
- [x] Skill file created at correct location
- [x] Proper YAML frontmatter with triggers
- [x] Comprehensive content covering all topics
- [x] References homelab patterns in k8s/ folder
- [x] Passes structure review
- [x] Passes content quality review

## Improvements Applied (from content review)
- [x] Added ephemeral containers debugging (`kubectl debug`)
- [x] Added external-secrets security best practices
- [x] Documented MetalLB, external-dns, cloudflared (new reference file)
- [x] Added cert-manager staging workflow
- [x] Fixed Helm default syntax in templates
- [x] Added additional trigger phrases

## Related PRs
<!-- Auto-updated by hooks -->
