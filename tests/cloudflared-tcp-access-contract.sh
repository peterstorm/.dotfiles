#!/bin/sh
# Contract: every raw-TCP / ssh ingress the cloudflared tunnel publishes is
# gated by a Cloudflare Access application for the same hostname.
#
# The tunnel is transport, not authorization. A `tcp://` or `ssh://` ingress on
# a proxied hostname with no Access application is an unauthenticated port on
# the internet (the inference API, or sshd). Terraform and the ConfigMap are
# applied by different tools at different times, so nothing else ties them
# together: this test does. Also pins the ssh-desktop wiring the Mac relies on.
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CONFIGMAP="$ROOT/k8s/argocd-homelab/cloudflared/configmap.yaml"
TF="$ROOT/k8s/terraform-homelab/cloudflare/main.tf"
DARWIN="$ROOT/roles/home-manager/core-apps/darwin/default.nix"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$CONFIGMAP" "$TF" "$DARWIN"; do
  [ -f "$f" ] || fail "missing $f"
done

# Hostnames whose ingress service is tcp:// or ssh:// (the line after `hostname:`).
raw_hosts="$(awk '
  /- hostname:/ { host = $3; next }
  /^[[:space:]]+service:[[:space:]]+(tcp|ssh):\/\// { print host }
' "$CONFIGMAP")"

[ -n "$raw_hosts" ] || fail "found no tcp:// or ssh:// ingress; the parser or the ConfigMap changed shape"

checked=0
for host in $raw_hosts; do
  grep -Eq "^[[:space:]]*domain[[:space:]]*=[[:space:]]*\"$host\"" "$TF" \
    || fail "$host is published as raw TCP/ssh but has no cloudflare_zero_trust_access_application in $TF"
  checked=$((checked + 1))
done

# Every Access application must be self_hosted with a policy attached: a bare
# application with no policies does not gate anything.
apps="$(grep -c '^resource "cloudflare_zero_trust_access_application"' "$TF")"
policies="$(grep -c '^[[:space:]]*policies[[:space:]]*=' "$TF")"
[ "$apps" = "$policies" ] || fail "$apps Access applications but $policies carry a policies list"

# ssh-desktop is reachable and uses its own token (not vllm-tcp's).
grep -Fq 'ssh://192.168.0.80:22' "$CONFIGMAP" \
  || fail "ssh-desktop must forward to desktop's sshd on 192.168.0.80:22"
grep -Fq 'resource "cloudflare_zero_trust_access_service_token" "ssh_desktop"' "$TF" \
  || fail "ssh-desktop needs its own service token, separate from vllm-tcp's"
grep -Fq 'token_id = cloudflare_zero_trust_access_service_token.ssh_desktop.id' "$TF" \
  || fail "the ssh-desktop policy must admit the ssh-desktop token, not another"

# The Mac's `desktop` host goes through the tunnel and keeps the token out of argv.
grep -Fq 'hostname = "ssh-desktop.peterstorm.io"' "$DARWIN" \
  || fail "darwin ssh host 'desktop' must target ssh-desktop.peterstorm.io"
# shellcheck disable=SC2016 # a literal Nix/shell snippet, not an expansion
grep -Fq 'TUNNEL_SERVICE_TOKEN_ID="$CF_ACCESS_SSH_CLIENT_ID"' "$DARWIN" \
  || fail "the ssh proxy must pass the token through the environment, not argv"
if grep -E 'cloudflared.*access ssh.*--service-token' "$DARWIN" >/dev/null; then
  fail "service-token flags put the secret in the process table; use TUNNEL_SERVICE_TOKEN_*"
fi

printf 'PASS: cloudflared raw-TCP Access contract (%s gated hostnames)\n' "$checked"
