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

if ((fail != 0)); then
  printf '\nGuardrail checks failed.\n' >&2
  exit 1
fi

printf '\nGuardrail checks passed.\n'
