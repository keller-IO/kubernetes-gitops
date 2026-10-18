#!/usr/bin/env bash
# Render an isolated source copy with synthetic SOPS payloads, never real keys.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output="$(realpath -m "${1:?Usage: render-all.sh OUTPUT_DIRECTORY}")"
mkdir -p "$output"
if [[ -n "$(find "$output" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "Render output directory must be empty: $output" >&2
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Override caller keys so this path cannot accidentally decrypt production data.
unset SOPS_AGE_KEY SOPS_AGE_KEY_CMD
export SOPS_AGE_KEY_FILE="$work/test.agekey"
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>"$work/age.log"
recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
python3 "$repo_root/scripts/ci/synthetic-secrets.py" "$repo_root" "$work/repo" "$recipient"
for dir in "$work/repo"/apps/overlays/main/*/ "$work/repo"/infrastructure/base/*/; do
  if [[ ! -f "${dir}kustomization.yaml" ]]; then
    echo "ERROR: selected GitOps directory lacks kustomization.yaml: ${dir#"$work/repo/"}" >&2
    exit 1
  fi
  relative="${dir#"$work/repo/"}"
  name="${relative//\//_}"
  echo "== rendering $relative"
  bash "$work/repo/scripts/render.sh" "$dir" > "$output/${name%_}.yaml"
done
# Applications, ApplicationSets, AppProjects and standalone Applications are
# deployed by root too; checking app directories alone misses this control plane.
for file in "$work/repo"/clusters/main/*.yaml; do
  cp "$file" "$output/clusters_main_$(basename "$file")"
done
