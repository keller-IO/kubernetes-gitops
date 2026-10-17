#!/usr/bin/env bash
# Render the same Kustomize and Helm sources ArgoCD uses.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(cd "${1:?Usage: scripts/render.sh DIRECTORY}" && pwd)"

kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$dir"

if [[ "$dir" == "$repo_root/apps/overlays/main/goloom" ]]; then
  appset="$repo_root/clusters/main/appset-apps.yaml"
  source='.spec.template.spec.sources[0]'
  url="$(yq -er "$source.repoURL" "$appset")"
  revision="$(yq -er "$source.targetRevision" "$appset")"
  chart="$(yq -er "$source.path" "$appset")"
  release="$(yq -er "$source.helm.releaseName" "$appset")"
  values="$(yq -er "$source.helm.valueFiles[0]" "$appset")"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$revision" "$url" "$work/chart"
  printf '\n---\n'
  helm template "$release" "$work/chart/$chart" --namespace goloom --include-crds \
    --values "$repo_root/${values#\$values/}"
fi
