#!/usr/bin/env bash
# Check the actual upstream render before accepting a chart or image update.
set -euo pipefail
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
bash scripts/render.sh apps/overlays/main/goloom >"$rendered"

yq -e 'select(.kind == "Deployment" and .metadata.name == "goloom") |
  .spec.replicas == 1 and .spec.strategy.type == "Recreate" and
  .spec.template.spec.serviceAccountName == "goloom" and
  .spec.template.spec.securityContext.runAsNonRoot == true and
  .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault" and
  .spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation == false and
  .spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem == true and
  .spec.template.spec.containers[0].securityContext.capabilities.drop[0] == "ALL" and
  .spec.template.spec.containers[0].resources.requests.memory == "128Mi" and
  .spec.template.spec.containers[0].resources.limits.memory == "512Mi" and
  .spec.template.spec.volumes[0].persistentVolumeClaim.claimName == "goloom-data" and
  (.spec.template.spec.volumes[1] | has("emptyDir"))
' "$rendered" >/dev/null
yq -e 'select(.kind == "ServiceAccount" and .metadata.name == "goloom") |
  .automountServiceAccountToken == false' "$rendered" >/dev/null
yq -e 'select(.kind == "PersistentVolumeClaim" and .metadata.name == "goloom-data") |
  .spec.storageClassName == "ceph-rbd" and .spec.resources.requests.storage == "5Gi"
' "$rendered" >/dev/null
echo "Goloom upstream render: security, SQLite/Recreate and existing PVC contract passed."
