#!/usr/bin/env bash
# Render Kustomize plus declared Git/Helm sources using local $ref values.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dir="$(cd "${1:?Usage: scripts/render.sh DIRECTORY}" && pwd)"
relative_dir="${dir#"$repo_root/"}"
name="$(basename "$dir")"
kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$dir"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for appset in "$repo_root"/clusters/main/appset-*.yaml; do
  template="$(yq -o=json '.spec.template' "$appset")"
  mapfile -t refs < <(jq -r --arg path "$relative_dir" '
    .spec.sources[]? | select(.path == $path and .ref != null) | .ref
  ' <<<"$template")
  for ref in "${refs[@]}"; do
    namespace="$(jq -r '.spec.destination.namespace // "default"' <<<"$template")"
    namespace="${namespace//\{\{.path.basename\}\}/$name}"
    app_name="$(jq -r '.metadata.name' <<<"$template")"
    app_name="${app_name//\{\{.path.basename\}\}/$name}"
    mapfile -t sources < <(jq -c --arg prefix "\$$ref/" '
      .spec.sources[]? | select(any(.helm.valueFiles[]?; startswith($prefix)))
    ' <<<"$template")
    for source in "${sources[@]}"; do
      url="$(jq -r '.repoURL' <<<"$source")"
      revision="$(jq -r '.targetRevision' <<<"$source")"
      chart="$(jq -r '.path' <<<"$source")"
      release="$(jq -r --arg name "$app_name" '.helm.releaseName // $name' <<<"$source")"
      checkout="$(mktemp -d "$work/chart.XXXXXX")"
      git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$revision" "$url" "$checkout"
      values_args=()
      mapfile -t values_files < <(jq -r '.helm.valueFiles[]' <<<"$source")
      for values in "${values_files[@]}"; do
        prefix="\$$ref/"
        case "$values" in
          "$prefix"*) values_args+=(--values "$repo_root/${values#"$prefix"}") ;;
          '$'*) echo "Unsupported external values reference: $values" >&2; exit 1 ;;
          *) values_args+=(--values "$checkout/$chart/$values") ;;
        esac
      done
      printf '\n---\n'
      helm template "$release" "$checkout/$chart" --namespace "$namespace" --include-crds "${values_args[@]}"
    done
  done
done
