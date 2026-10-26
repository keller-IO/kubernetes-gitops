#!/usr/bin/env bash
# Regression test for the Ingress ignoreDifferences rule in appset-apps.yaml.
# The rule must hide exactly the HTTP-01 solver paths that cert-manager adds
# with http01-edit-in-place (otherwise selfHeal removes them mid-challenge,
# PR #389 review) and nothing else (otherwise real Ingress drift goes unseen).
# Argo CD deletes every path an expression selects from live and desired state
# before diffing; this test does the same with jq.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
appset="$repo_root/clusters/main/appset-apps.yaml"

mapfile -t exprs < <(yq -r '
  .spec.template.spec.ignoreDifferences[]
  | select(.group == "networking.k8s.io" and .kind == "Ingress")
  | .jqPathExpressions[]' "$appset")
if ((${#exprs[@]} == 0)); then
  printf '%s: no Ingress jqPathExpressions found\n' "$appset" >&2
  exit 1
fi

normalize() {
  local doc="$1" expr
  for expr in "${exprs[@]}"; do
    doc="$(jq -c "del($expr)" <<<"$doc")"
  done
  jq -S -c . <<<"$doc"
}

desired='{"spec":{"rules":[
  {"host":"stream.example.org","http":{"paths":[
    {"path":"/","pathType":"Prefix","backend":{"service":{"name":"app","port":{"number":80}}}}]}},
  {"host":"other.example.org"}]}}'

expect_same() {
  local name="$1" live="$2"
  if [[ "$(normalize "$live")" != "$(normalize "$desired")" ]]; then
    printf 'Expected %s to be ignored, but Argo CD would report drift\n' "$name" >&2
    exit 1
  fi
}

expect_drift() {
  local name="$1" live="$2"
  if [[ "$(normalize "$live")" == "$(normalize "$desired")" ]]; then
    printf 'Expected %s to stay visible as drift, but the ignore rule hides it\n' "$name" >&2
    exit 1
  fi
}

# What cert-manager writes during an edit-in-place challenge.
expect_same solver-path "$(jq -c '.spec.rules[0].http.paths += [
  {"path":"/.well-known/acme-challenge/tok3n","pathType":"ImplementationSpecific",
   "backend":{"service":{"name":"cm-acme-http-solver-abcde","port":{"number":8089}}}}]' <<<"$desired")"

expect_drift changed-backend "$(jq -c '.spec.rules[0].http.paths[0].backend.service.name = "evil"' <<<"$desired")"
expect_drift extra-path "$(jq -c '.spec.rules[0].http.paths += [
  {"path":"/admin","pathType":"Prefix","backend":{"service":{"name":"app","port":{"number":80}}}}]' <<<"$desired")"
expect_drift acme-not-prefix "$(jq -c '.spec.rules[0].http.paths += [
  {"path":"/x/.well-known/acme-challenge/tok3n","pathType":"Prefix","backend":{"service":{"name":"app","port":{"number":80}}}}]' <<<"$desired")"
expect_drift removed-rule "$(jq -c 'del(.spec.rules[1])' <<<"$desired")"

printf 'ACME ignore rule test passed.\n'
