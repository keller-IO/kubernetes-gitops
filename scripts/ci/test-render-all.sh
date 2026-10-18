#!/usr/bin/env bash
# A new AppSet-selected directory must never disappear from the render gate.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/repo/scripts/ci" "$work/repo/apps/overlays/main/new-app" \
  "$work/repo/infrastructure/base" "$work/repo/clusters/main"
cp "$root/scripts/ci/"{render-all.sh,synthetic-secrets.py} "$work/repo/scripts/ci/"
cp "$root/scripts/render.sh" "$work/repo/scripts/"
cat >"$work/repo/clusters/main/appset-apps.yaml" <<'YAML'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata: {name: fixture}
spec: {template: {spec: {}}}
YAML
cat >"$work/repo/apps/overlays/main/new-app/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: new-app}
spec: {replicas: 1}
YAML
if bash "$work/repo/scripts/ci/render-all.sh" "$work/rejected" >"$work/negative.log" 2>&1; then
  echo "ERROR: directory without Kustomization was silently accepted" >&2
  exit 1
fi
rg -q 'selected GitOps directory lacks kustomization.yaml' "$work/negative.log"
cat >"$work/repo/apps/overlays/main/new-app/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: [deployment.yaml]
YAML
# Complete the fixture's empty source groups without globbing missing paths.
mkdir -p "$work/repo/infrastructure/base/empty"
cp "$work/repo/apps/overlays/main/new-app/"{kustomization.yaml,deployment.yaml} "$work/repo/infrastructure/base/empty/"
cat >"$work/repo/clusters/main/root.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: fixture}
YAML
bash "$work/repo/scripts/ci/render-all.sh" "$work/accepted"
rg -q 'name: new-app' "$work/accepted/apps_overlays_main_new-app.yaml"
echo 'Missing Kustomization rejection and source render coverage passed.'
