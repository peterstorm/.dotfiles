#!/usr/bin/env bash
# Evaluate the inference recording rules with promtool: render the Helm
# template, check its syntax, and run the unit tests in
# tests/fixtures/inference-recording-rules/ against it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/k8s/argocd-homelab/monitoring/templates/inference-recording-rules.yaml"
FIXTURES="$ROOT/tests/fixtures/inference-recording-rules"

# promtool and yq are not in the base system; borrow them from nixpkgs once.
if ! command -v promtool >/dev/null || ! command -v yq >/dev/null; then
  [[ -z "${INFERENCE_RULES_NIX_SHELL:-}" ]] || { echo "FAIL: promtool/yq unavailable" >&2; exit 1; }
  INFERENCE_RULES_NIX_SHELL=1 exec nix shell nixpkgs#prometheus.cli nixpkgs#yq-go -c bash "$0" "$@"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The template's only Helm expression is the release label; the rule groups are
# plain YAML under .spec.
grep -c '{{' "$TEMPLATE" | grep -qx 1 \
  || { echo "FAIL: $TEMPLATE gained Helm expressions this renderer does not know" >&2; exit 1; }
sed 's/{{ \.Release\.Name | quote }}/"monitoring"/' "$TEMPLATE" | yq '.spec' > "$work/rules.yml"
cp "$FIXTURES"/*.test.yml "$work/"

# Each inference:* name is recorded once per engine by design (the engine label
# keeps the series apart), so promtool's duplicate-rule lint is not a finding.
promtool check rules --lint=none "$work/rules.yml" >/dev/null
promtool test rules "$work"/*.test.yml

echo "PASS: inference recording rules evaluate as the unit tests expect"
