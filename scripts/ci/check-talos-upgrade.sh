#!/usr/bin/env bash
# Rendered safety contract for the Talos updater; no cluster or secrets needed.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"
component=infrastructure/base/system-upgrade-controller
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
kustomize build "$component" | yq -o=json -I=0 '.' | jq -s '.' >"$rendered"

jq -e '
  . as $objects |
  ([.[] | select(.kind == "Plan")] | length == 1) and
  ([.[] | select(.kind == "Plan")][0] |
    .metadata.name == "talos" and
    .metadata.namespace == "system-upgrade-controller" and
    .metadata.labels["app.kubernetes.io/component"] == "upgrade" and
    .metadata.labels["app.kubernetes.io/name"] == "talos-upgrade" and
    .spec.concurrency == 1 and .spec.exclusive == false and
    .spec.postCompleteDelay == "5m" and .spec.jobActiveDeadlineSecs == 5400 and
    .spec.nodeSelector.matchLabels["keller.io/talos-upgrade"] == "enabled" and
    .spec.serviceAccountName == "talos-upgrade" and
    .spec.drain.force == false and .spec.drain.ignoreDaemonSets == true and
    .spec.drain.deleteEmptydirData == false and .spec.drain.timeout == "20m" and
    (.spec.drain.disableEviction // false) == false and
    (.spec.drain | has("gracePeriod") | not) and
    .spec.secrets[0].ignoreUpdates == true and
    .spec.secrets[0].name == "talosconfig" and
    .spec.secrets[0].path == "/var/run/secrets/talos.dev" and
    (.spec.upgrade.args | index("--talosconfig=/var/run/secrets/talos.dev/config") != null) and
    .spec.prepare.command == ["python3", "-c"] and
    .spec.prepare.args == ["$(PREFLIGHT_SCRIPT)"] and
    any(.spec.prepare.envs[]; .name == "PREFLIGHT_SCRIPT" and
      .valueFrom.configMapKeyRef.name == "talos-upgrade-preflight" and
      .valueFrom.configMapKeyRef.key == "preflight.py") and
    any(.spec.prepare.envs[]; .name == "DRAIN_KUBECTL_IMAGE" and
      .valueFrom.configMapKeyRef.key == "SYSTEM_UPGRADE_JOB_KUBECTL_IMAGE") and
    (.spec.upgrade.args | index("--drain=false") != null and index("--wait=false") != null and
      index("-e") != null and index("-n") != null and all(.[]; startswith("--insecure") | not)) and
    ([.spec.prepare, .spec.upgrade] | all(.[];
      .securityContext.privileged == false and .securityContext.runAsNonRoot == true and
      .securityContext.allowPrivilegeEscalation == false)) and
    (.spec.version as $version |
    .spec.upgrade.image == ("ghcr.io/siderolabs/talosctl:" + $version) and
    any(.spec.upgrade.args[]; startswith("--image=factory.talos.dev/nocloud-installer/") and endswith(":" + $version)))) and
  any(.[]; .kind == "ConfigMap" and .metadata.name == "talos-upgrade-preflight" and
    (.data["preflight.py"] | contains("wait_until_safe")) and
    (.data["preflight.py"] | contains("\"/var/run/secrets/talos.dev/config\""))) and
  ([.[] | select(.apiVersion == "talos.dev/v1alpha1" and .kind == "ServiceAccount")] | length == 1) and
  any(.[]; .apiVersion == "talos.dev/v1alpha1" and .kind == "ServiceAccount" and
    .metadata.name == "talosconfig" and .metadata.namespace == "system-upgrade-controller" and
    .spec.roles == ["os:admin"]) and
  any(.[]; .kind == "ConfigMap" and .metadata.name == "default-controller-env" and
    .data.SYSTEM_UPGRADE_JOB_IMAGE_PULL_POLICY == "IfNotPresent" and
    .data.SYSTEM_UPGRADE_JOB_PRIVILEGED == "false") and
  any(.[]; .kind == "Deployment" and .metadata.name == "system-upgrade-controller" and
    all(.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[];
      .labelSelector.matchLabels["app.kubernetes.io/component"] == "controller")) and
  all(.[] | select(.kind == "ClusterRole" and
      (.metadata.name == "talos-upgrade-preflight" or .metadata.name == "system-upgrade-controller-drainer"));
    all(.rules[];
      all(.resources[]?; . != "secrets" and . != "*") and
      (if any(.resources[]?; . == "pods") then all(.verbs[]; . == "get" or . == "list") else true end)))
' "$rendered" >/dev/null || {
  echo 'ERROR: unsafe or inconsistent rendered Talos upgrade configuration' >&2
  exit 1
}

# A cached controller image must not hide a nonexistent/mismatched release pin.
controller_version="$(yq '.images[] | select(.name == "rancher/system-upgrade-controller") | .newTag' "$component/kustomization.yaml")"
yq -o=json '.resources' "$component/kustomization.yaml" | jq -e --arg version "$controller_version" '
  any(.[]; . == ("https://github.com/rancher/system-upgrade-controller?ref=" + $version)) and
  any(.[]; . == ("https://raw.githubusercontent.com/rancher/system-upgrade-controller/" + $version + "/pkg/crds/yaml/generated/upgrade.cattle.io_plans.yaml"))
' >/dev/null

echo 'Talos rendered safety contract passed.'
