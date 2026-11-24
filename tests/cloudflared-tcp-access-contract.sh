#!/bin/sh
# Contract: every raw-TCP / ssh ingress the cloudflared tunnel publishes is
# gated by a Cloudflare Access application for the same hostname, the ssh host
# lists agree across ingress, terraform and the Mac, and a config edit rolls the
# cloudflared pod.
#
# The tunnel is transport, not authorization. A `tcp://` or `ssh://` ingress on
# a proxied hostname with no Access application is an unauthenticated port on
# the internet (the inference API, or sshd). Terraform, the cloudflared config
# and the Mac's home-manager are applied by different tools at different times,
# so nothing else ties them together: this test does.
# shellcheck disable=SC2016 # literal Nix/HCL/shell snippets, not expansions
set -eu

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CLOUDFLARED="$ROOT/k8s/argocd-homelab/cloudflared"
CONFIG="$CLOUDFLARED/config.yaml"
KUSTOMIZATION="$CLOUDFLARED/kustomization.yaml"
TF="$ROOT/k8s/terraform-homelab/cloudflare/main.tf"
DARWIN="$ROOT/roles/home-manager/core-apps/darwin/default.nix"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for f in "$CONFIG" "$KUSTOMIZATION" "$TF" "$DARWIN"; do
  [ -f "$f" ] || fail "missing $f"
done

# The words inside the [ ... ] on the first line of a file matching a pattern,
# one per line, sorted: `toset(["a", "b"])` and `[ "a" "b" ]` both give a, b.
oneline() { printf '%s' "$1" | tr '\n' ' '; }

list_words() { # list_words FILE PATTERN
  grep -E "$2" "$1" | head -n 1 | sed -n 's/.*\[\(.*\)\].*/\1/p' \
    | tr -c 'a-z0-9-\n' ' ' | tr -s ' ' '\n' | sed '/^$/d' | sort
}

# --- every raw-TCP / ssh ingress is gated ------------------------------------

# Hostnames whose ingress service is tcp:// or ssh:// (the line after `hostname:`).
raw_hosts="$(awk '
  /- hostname:/ { host = $3; next }
  /^[[:space:]]+service:[[:space:]]+(tcp|ssh):\/\// { print host }
' "$CONFIG")"

[ -n "$raw_hosts" ] || fail "found no tcp:// or ssh:// ingress; the parser or the config changed shape"

# The ssh hosts, by short name: the terraform set and the Mac's list.
tf_hosts="$(list_words "$TF" '^[[:space:]]*ssh_hosts[[:space:]]*=')"
mac_hosts="$(list_words "$DARWIN" '^[[:space:]]*sshHosts[[:space:]]*=')"
[ -n "$tf_hosts" ] || fail "no local.ssh_hosts found in $TF"
ingress_ssh_hosts=""

checked=0
for host in $raw_hosts; do
  case "$host" in
    ssh-*.peterstorm.io)
      name="${host#ssh-}"
      name="${name%.peterstorm.io}"
      ingress_ssh_hosts="$ingress_ssh_hosts$name
"
      echo "$tf_hosts" | grep -Fxq "$name" \
        || fail "$host is published but '$name' is not in local.ssh_hosts, so it has no Access application"
      ;;
    *)
      grep -Eq "^[[:space:]]*domain[[:space:]]*=[[:space:]]*\"$host\"" "$TF" \
        || fail "$host is published as raw TCP/ssh but has no cloudflare_zero_trust_access_application in $TF"
      ;;
  esac
  checked=$((checked + 1))
done

# The ssh hosts are one set in three places: ingress, terraform, the Mac.
ingress_sorted="$(printf '%s' "$ingress_ssh_hosts" | sed '/^$/d' | sort)"
[ "$ingress_sorted" = "$tf_hosts" ] \
  || fail "ssh hosts differ: ingress [$(oneline "$ingress_sorted")] vs terraform [$(oneline "$tf_hosts")]"
[ "$mac_hosts" = "$tf_hosts" ] \
  || fail "ssh hosts differ: Mac sshHosts [$(oneline "$mac_hosts")] vs terraform [$(oneline "$tf_hosts")]"

# --- the Access application behind ssh_hosts ---------------------------------

# Every Access application must carry a policy: a bare one gates nothing.
apps="$(grep -c '^resource "cloudflare_zero_trust_access_application"' "$TF")"
policies="$(grep -c '^[[:space:]]*policies[[:space:]]*=' "$TF")"
[ "$apps" = "$policies" ] || fail "$apps Access applications but $policies carry a policies list"

grep -Fq 'domain           = "ssh-${each.key}.peterstorm.io"' "$TF" \
  || fail "the ssh Access application must cover ssh-<host>.peterstorm.io for each host"
# One token per host, and each host's policy admits only its own token.
grep -Fq 'resource "cloudflare_zero_trust_access_service_token" "ssh"' "$TF" \
  || fail "ssh hosts need their own service tokens, separate from vllm-tcp's"
grep -Fq 'token_id = cloudflare_zero_trust_access_service_token.ssh[each.key].id' "$TF" \
  || fail "each ssh host's policy must admit that host's own token (ssh[each.key])"
grep -Fq 'id         = cloudflare_zero_trust_access_policy.ssh[each.key].id' "$TF" \
  || fail "each ssh host's application must use that host's own policy"

# --- the Mac: through the tunnel, token never in argv ------------------------

grep -Fq 'hostname = "ssh-${host}.peterstorm.io"' "$DARWIN" \
  || fail "darwin ssh hosts must target ssh-<host>.peterstorm.io"
grep -Fq 'TUNNEL_SERVICE_TOKEN_ID="$CF_ACCESS_SSH_CLIENT_ID"' "$DARWIN" \
  || fail "the ssh proxy must pass the token through the environment, not argv"
if grep -E 'cloudflared.*access ssh.*--service-token' "$DARWIN" >/dev/null; then
  fail "service-token flags put the secret in the process table; use TUNNEL_SERVICE_TOKEN_*"
fi

# The Mac offers only the key made for these hosts, never its general-purpose one,
# and that key's public half is what the servers authorize.
grep -Fq 'IdentityFile = "~/.ssh/id_ed25519_homelab";' "$DARWIN" \
  || fail "darwin ssh hosts must use the dedicated ~/.ssh/id_ed25519_homelab identity"
grep -Fq 'IdentitiesOnly = "yes";' "$DARWIN" \
  || fail "darwin ssh hosts must set IdentitiesOnly so no other key is offered"
grep -Eq '^ssh-ed25519 [A-Za-z0-9+/=]+ hansen142-corp-mac' "$ROOT/authorized_keys.txt" \
  || fail "authorized_keys.txt must carry the Mac's dedicated homelab key (comment hansen142-corp-mac...)"

# --- a config edit rolls the cloudflared pod ---------------------------------

# The Deployment mounts the config with subPath, which Kubernetes never
# refreshes in a running pod. Only a generated, content-hashed ConfigMap changes
# the pod template and so rolls it.
grep -Fq 'configMapGenerator:' "$KUSTOMIZATION" \
  || fail "cloudflared-config must be a configMapGenerator so a config edit rolls the pod"
grep -Fq 'name: cloudflared-config' "$KUSTOMIZATION" \
  || fail "the generator must be named cloudflared-config (the Deployment's reference)"
if grep -Eq '^[[:space:]]*-[[:space:]]+configmap\.yaml' "$KUSTOMIZATION"; then
  fail "a plain configmap.yaml resource brings back the config that never reloads"
fi
[ ! -f "$CLOUDFLARED/configmap.yaml" ] || fail "configmap.yaml must not exist beside the generated config"

printf 'PASS: cloudflared raw-TCP Access contract (%s gated hostnames, ssh hosts: %s)\n' "$checked" "$(oneline "$tf_hosts")"
