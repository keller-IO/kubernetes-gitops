#!/usr/bin/env bash
# Render every overlay/base and fail on:
#
#   1. Any HorizontalPodAutoscaler that isn't explicitly allowlisted. A chart
#      can bring one in unasked and silently void an explicit replicaCount —
#      that scaled Collabora to 55 replicas and took the cluster down
#      (docs/learnings/collabora-hpa-runaway.md). A set replicaCount is not
#      proof it takes effect; this check inspects the rendered manifest so
#      nobody has to remember to.
#   2. Any HorizontalPodAutoscaler that targets resource "memory", allowlisted
#      or not. Per-pod memory doesn't fall as replicas rise, so a
#      memory-based HPA is a structurally unbounded upward spiral, not a
#      tuning problem — this is never an acceptable exception.
#
# Requires on PATH: kustomize, helm (kustomize shells out to it for
# --enable-helm), yq (mikefarah/yq "yq-go"), jq, and a ksops stub (see
# .github/workflows/ci.yml for the exact stub CI installs).
#
# Allowlist: scripts/ci/known-gaps/hpa-allowlist.txt ("<namespace>/<name>" per
# line). Empty by design as of 2026-07-28 — no HPA currently renders here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

allowlist="scripts/ci/known-gaps/hpa-allowlist.txt"
fail=0
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

allowed_keys="$(grep -vE '^[[:space:]]*(#|$)' "$allowlist" | awk '{print $1}' || true)"

is_allowed() {
  local key="$1"
  [[ -n "$allowed_keys" ]] && grep -qxF "$key" <<<"$allowed_keys"
}

for dir in apps/overlays/main/*/ infrastructure/base/*/; do
  [ -f "${dir}kustomization.yaml" ] || continue

  rendered="$work/rendered.yaml"
  kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$dir" > "$rendered"

  hpas_json="$work/hpas.json"
  : > "$hpas_json"
  yq eval-all -o=json 'select(.kind == "HorizontalPodAutoscaler")' "$rendered" > "$hpas_json" 2>/dev/null || true
  [ -s "$hpas_json" ] || continue

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if is_allowed "$key"; then
      printf 'INFO: %s -- HPA %s is allowlisted (%s)\n' "$dir" "$key" "$allowlist"
    else
      printf 'ERROR: %s renders an unexpected HorizontalPodAutoscaler %s\n' "$dir" "$key" >&2
      printf '  A chart may bring an HPA in unasked (docs/learnings/collabora-hpa-runaway.md).\n' >&2
      printf '  If intentional and CPU-based, allowlist it in %s with a reason.\n' "$allowlist" >&2
      fail=1
    fi
  done < <(jq -s -r '.[] | (.metadata.namespace // "-") + "/" + .metadata.name' "$hpas_json")

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf 'ERROR: %s -- HPA %s autoscales on memory\n' "$dir" "$key" >&2
    printf '  Per-pod memory does not fall as replicas rise, so this is a structurally\n' >&2
    printf '  unbounded spiral, not a tuning problem (docs/learnings/collabora-hpa-runaway.md).\n' >&2
    printf '  Not allowlistable -- use a CPU metric, or remove autoscaling.\n' >&2
    fail=1
  done < <(jq -s -r '
      .[]
      | select(([.spec.metrics[]? | select(.type == "Resource" and .resource.name == "memory")] | length) > 0)
      | (.metadata.namespace // "-") + "/" + .metadata.name
    ' "$hpas_json")
done

if ((fail != 0)); then
  printf '\nHPA safety checks failed.\n' >&2
  exit 1
fi

printf '\nHPA safety checks passed.\n'
