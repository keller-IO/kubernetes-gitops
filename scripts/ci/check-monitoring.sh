#!/usr/bin/env bash
# Rendered contracts for Talos scrapes and alert email.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if (($# > 1)); then
  echo "Usage: $0 [RENDERED_MONITORING_MANIFEST]" >&2
  exit 2
fi

if (($# == 1)); then
  rendered="$1"
else
  rendered="$work/monitoring.yaml"
  bash "$repo_root/scripts/render.sh" "$repo_root/infrastructure/base/monitoring" >"$rendered"
fi

yq -o=json -I=0 '.' "$rendered" | jq -s '.' >"$work/objects.json"
fail=0

unwanted_resources="$(jq -r '
  .[]
  | select(
      (.kind == "Service" or .kind == "VMServiceScrape") and
      (.metadata.name | test("-(kube-controller-manager|kube-scheduler|kube-etcd)$"))
    )
  | "\(.kind)/\(.metadata.name)"
' "$work/objects.json")"
if [[ -n "$unwanted_resources" ]]; then
  printf 'ERROR: monitoring renders unsupported Talos control-plane scrape resources:\n%s\n' \
    "$unwanted_resources" >&2
  fail=1
fi

unwanted_rule_groups="$(jq -r '
  .[] as $resource
  | $resource.spec.groups[]?
  | select(.name == "etcd" or .name == "kube-scheduler.rules" or
      .name == "kubernetes-system-controller-manager" or
      .name == "kubernetes-system-scheduler")
  | "\($resource.kind)/\($resource.metadata.name): \(.name)"
' "$work/objects.json")"
if [[ -n "$unwanted_rule_groups" ]]; then
  printf 'ERROR: monitoring renders unsupported Talos control-plane rule groups:\n%s\n' \
    "$unwanted_rule_groups" >&2
  fail=1
fi

sync_config_count="$(jq '[.[] | select(
  .kind == "ConfigMap" and .metadata.labels["app.kubernetes.io/component"] == "syncJob" and
  (.data["config.yaml"]? != null)
)] | length' "$work/objects.json")"
if [[ "$sync_config_count" != "1" ]]; then
  printf 'ERROR: expected one monitoring sync-job ConfigMap, found %s\n' "$sync_config_count" >&2
  fail=1
else
  jq -r '.[] | select(
    .kind == "ConfigMap" and .metadata.labels["app.kubernetes.io/component"] == "syncJob" and
    (.data["config.yaml"]? != null)
  ) | .data["config.yaml"]' "$work/objects.json" >"$work/sync-config.yaml"

  if ! yq -e '
    .rules.groups."kube-scheduler.rules".enabled == false and
    .rules.groups."kubernetes-system-controller-manager".enabled == false and
    .rules.groups."kubernetes-system-scheduler".enabled == false and
    ([.rules.sources[] | select(.url == "https://raw.githubusercontent.com/monitoring-mixins/website/master/assets/etcd/alerts.yaml")] | length == 1) and
    ([.rules.sources[] | select(.url == "https://raw.githubusercontent.com/monitoring-mixins/website/master/assets/etcd/alerts.yaml")][0].enabled == false)
  ' "$work/sync-config.yaml" >/dev/null; then
    echo 'ERROR: monitoring sync-job does not disable unsupported Talos control-plane rule groups' >&2
    fail=1
  fi
fi

alertmanager_config="$(jq -r '
  .[] | select(.kind == "Secret" and .metadata.name == "vmalertmanager-vm-k8s-stack-alertmanager")
  | .stringData["alertmanager.yaml"] // empty
' "$work/objects.json")"
if [[ -z "$alertmanager_config" ]] ||
  ! printf '%s\n' "$alertmanager_config" | yq -o=json '.' | jq -e '
    [.receivers[].email_configs[]?] as $emails
    | ($emails | length > 0) and
      ([$emails[] | select(
        ((.headers.Subject // "") | length) > 100 or
        ((.headers.Subject // "") | length) == 0 or
        ((.text // "") | length) == 0
      )] | length == 0)
  ' >/dev/null; then
  echo 'ERROR: rendered Alertmanager email needs a short subject and plain-text body' >&2
  fail=1
fi

if ((fail != 0)); then
  exit 1
fi

echo 'Monitoring rendered contract passed.'
