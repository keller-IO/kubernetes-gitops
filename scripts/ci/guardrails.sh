#!/usr/bin/env bash
# Repository safety checks for GitOps and AI-assisted changes.

set -euo pipefail

fail=0

section() {
  printf '\n==> %s\n' "$1"
}

report() {
  printf 'ERROR: %s\n' "$1" >&2
  fail=1
}

matches=""

section "No floating container images"
matches="$(grep -RInE 'image:[[:space:]]*["'\''"]?[^#"'\''[:space:]]+:latest(@sha256:[a-f0-9]+)?["'\''"]?' \
  apps infrastructure clusters --include='*.yaml' --include='*.yml' --exclude-dir=charts || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "found image references using :latest"
fi

matches="$(grep -RInE 'imagePullPolicy:[[:space:]]*Always([[:space:]]*(#.*)?)?$' \
  apps infrastructure clusters --include='*.yaml' --include='*.yml' --exclude-dir=charts || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "found imagePullPolicy: Always"
fi

section "No obvious plaintext secret placeholders"
matches="$(find apps infrastructure clusters -path '*/charts/*' -prune -o \( -name '*.yaml' -o -name '*.yml' \) -print \
  | grep -v '\.sops\.ya\?ml$' \
  | xargs grep -InE '(^|[^A-Z0-9_])(password|passwd|token|api[_-]?key|client[_-]?secret):[[:space:]]*["'\''"]?[^[:space:]#"'\''{]+' \
  | grep -vE 'secretName:|secretRef:|secretKeyRef:|name: .*secret|kind: Secret|metadata:|app.kubernetes.io|REPLACE_ME|CHANGE ME|PLACEHOLDER|placeholder|\$\{' || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "possible plaintext secret outside *.sops.yaml"
fi

section "No live-cluster mutations in automation"
automation_files=()
[[ -f justfile ]] && automation_files+=(justfile)
while IFS= read -r -d '' f; do automation_files+=("$f"); done < <(
  find .github .forgejo scripts -type f \
    \( -name '*.yaml' -o -name '*.yml' -o -name '*.sh' -o -name '*.bash' \) \
    -print0 2>/dev/null || true
)

if ((${#automation_files[@]} > 0)); then
  matches="$(grep -InE '(^|[;&|[:space:]])kubectl[[:space:]]+(apply|delete|patch|replace|scale|cordon|drain|taint|create|edit)|(^|[;&|[:space:]])talosctl[[:space:]]+(apply-config|reset|wipe|reboot|upgrade)' \
    "${automation_files[@]}" \
    | grep -v 'guardrails: allow-live-mutation' || true)"
  if [[ -n "$matches" ]]; then
    printf '%s\n' "$matches"
    report "found mutating kubectl/talosctl command in automation"
  fi
fi

section "Agent-facing Kubernetes access stays read-only"
matches="$(grep -RInE 'verbs:[[:space:]]*\[[^]]*(create|update|patch|delete|deletecollection|escalate|bind|impersonate)' \
  infrastructure/base/kubernetes-mcp apps/base/kubernetes-mcp 2>/dev/null || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "kubernetes-mcp RBAC contains write-like verbs"
fi

matches="$(grep -RInE 'resources:[[:space:]]*\[[^]]*secrets' infrastructure/base/kubernetes-mcp apps/base/kubernetes-mcp 2>/dev/null || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "kubernetes-mcp RBAC exposes secrets"
fi

# Find single-doc CR files by exact apiVersion + kind (repo convention: one CR
# per file, verified for every file this matches as of 2026-07-28).
find_operator_crs() {
  local api="$1" kind="$2" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qE "^kind:[[:space:]]*${kind}[[:space:]]*\$" "$f" && printf '%s\n' "$f"
  done < <(grep -rlE "^apiVersion:[[:space:]]*${api}[[:space:]]*\$" apps infrastructure \
    --include='*.yaml' --exclude-dir=charts 2>/dev/null || true)
}

section "Operator CRs set resources (no BestEffort pods)"
resources_allowlist="scripts/ci/known-gaps/missing-resources.txt"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qE '^[[:space:]]*resources:' "$f" && continue
  grep -qxF "$f" "$resources_allowlist" 2>/dev/null && continue
  report "$f: operator CR has no spec.resources — BestEffort pods are OOM-killed first and the scheduler balances nodes by requests only, so it places them blind (docs/learnings/collabora-hpa-runaway.md; fixed for MariaDB in commit 098d145). Set resources, or add '$f' to $resources_allowlist with a reason."
done < <({ find_operator_crs 'postgresql\.cnpg\.io/v1' 'Cluster'; find_operator_crs 'k8s\.mariadb\.com/v1alpha1' 'MariaDB'; })

section "Operator CRs pin an explicit image"
image_allowlist="scripts/ci/known-gaps/unpinned-images.txt"
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qE '^[[:space:]]*imageName:' "$f" && continue
  grep -qxF "$f" "$image_allowlist" 2>/dev/null && continue
  report "$f: CNPG Cluster has no spec.imageName — the operator picks its own Postgres version, invisible to Git and Renovate. Pin it, or add '$f' to $image_allowlist."
done < <(find_operator_crs 'postgresql\.cnpg\.io/v1' 'Cluster')
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -qE '^[[:space:]]*image:' "$f" && continue
  grep -qxF "$f" "$image_allowlist" 2>/dev/null && continue
  report "$f: MariaDB CR has no spec.image — the mariadb-operator picks its own default version, invisible to Git and Renovate. Pin it, or add '$f' to $image_allowlist."
done < <(find_operator_crs 'k8s\.mariadb\.com/v1alpha1' 'MariaDB')

section "Every component declares its own namespace"
ns_allowlist="scripts/ci/known-gaps/missing-namespace.txt"
for d in apps/base/*/ infrastructure/base/*/; do
  [[ -f "${d}kustomization.yaml" ]] || continue
  rel="${d%/}"
  has_ns=0
  for f in "$d"*.yaml; do
    [[ -f "$f" ]] || continue
    if grep -qE '^kind:[[:space:]]*Namespace[[:space:]]*$' "$f"; then
      has_ns=1
      break
    fi
  done
  ((has_ns)) && continue
  grep -qxF "$rel" "$ns_allowlist" 2>/dev/null && continue
  report "$rel: no explicit Namespace resource — relying on ArgoCD's CreateNamespace=true yields a namespace with no PodSecurity labels (the crowdsec-agent 0/3 incident, 2026-07-28). Add a namespace.yaml, or add '$rel' to $ns_allowlist."
done

section "ignoreDifferences only lives in the ApplicationSet template"
matches="$(grep -RIn 'ignoreDifferences' apps infrastructure clusters \
  --include='*.yaml' --include='*.yml' --exclude-dir=charts 2>/dev/null \
  | grep -vE '^clusters/main/appset-(apps|infrastructure)\.yaml:' || true)"
if [[ -n "$matches" ]]; then
  printf '%s\n' "$matches"
  report "ignoreDifferences found outside clusters/main/appset-*.yaml — a patch on a generated Application is overwritten by the ApplicationSet controller within a second (docs/learnings/argocd-dauerhaft-outofsync.md). Move it into the ApplicationSet template."
fi

if ((fail != 0)); then
  printf '\nGuardrail checks failed.\n' >&2
  exit 1
fi

printf '\nGuardrail checks passed.\n'
