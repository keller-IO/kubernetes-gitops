#!/usr/bin/env bash
# Validate an existing render, including CRs against its exact rendered CRDs.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="${1:?Usage: scripts/ci/check-schemas.sh RENDERED_DIRECTORY}"
config="$repo_root/scripts/ci/config.json"
version="$(jq -er '.kubernetesVersion | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$config")"
revision="$(jq -er '.kubernetesSchemaRevision | select(test("^[0-9a-f]{40}$"))' "$config")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

python3 "$repo_root/scripts/ci/prepare-schemas.py" "$rendered" "$work" "$config"
kubeconform -strict -summary -kubernetes-version "$version" \
  -schema-location "$work/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -schema-location "https://raw.githubusercontent.com/yannh/kubernetes-json-schema/$revision/{{.NormalizedKubernetesVersion}}-standalone{{.StrictSuffix}}/{{.ResourceKind}}{{.KindSuffix}}.json" \
  "$rendered"
