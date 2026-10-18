#!/usr/bin/env bash
# Real install/upgrade pilot. Scope: a unique disposable Kind cluster only.
# Target: explicit throwaway kubeconfig and localhost API, checked before every
# kubectl/Helm call. Rollback: EXIT trap deletes that named cluster and age key.
# Never source a kubeconfig, production secret, .env, or external credentials.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HERE="$ROOT/scripts/ci/integration"
MODE="${CI_INTEGRATION_MODE:-install}"
BASE="${CI_BASE_REVISION:-origin/main}"
CANDIDATE="${CI_CANDIDATE_REVISION:-HEAD}"
ARTIFACTS="${CI_INTEGRATION_ARTIFACTS:-$ROOT/.artifacts/integration}"
while (($#)); do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    --candidate) CANDIDATE="$2"; shift 2 ;;
    --artifacts) ARTIFACTS="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$MODE" == install || "$MODE" == upgrade ]] || { echo "mode must be install or upgrade" >&2; exit 2; }
for tool in kind kubectl helm git jq yq sops age-keygen python3 curl rg; do
  command -v "$tool" >/dev/null || { echo "Missing $tool; run through nix develop" >&2; exit 2; }
done
python3 -c 'import yaml'
CANDIDATE="$(git rev-parse --verify "${CANDIDATE}^{commit}")"
[[ ! "$BASE" =~ ^0+$ ]] || BASE="${CANDIDATE}^"
BASE="$(git rev-parse --verify "${BASE}^{commit}")"
ARTIFACTS="$ARTIFACTS/$MODE"
mkdir -p "$ARTIFACTS"
ARTIFACTS="$(realpath "$ARTIFACTS")"
TASK_TMP="$(mktemp -d -t keller-ci-XXXXXXXX)"
CLUSTER="keller-ci-$(python3 -c 'import uuid; print(uuid.uuid4().hex)')"
export CI_KUBECONFIG="$TASK_TMP/kubeconfig" KUBECONFIG="$TASK_TMP/kubeconfig"
export CI_CONTEXT="kind-$CLUSTER"
CI_SERVER=""
export CI_SERVER
export SOPS_AGE_KEY_FILE="$TASK_TMP/age-key.txt"
unset SOPS_AGE_KEY SOPS_AGE_KEY_CMD
# shellcheck source=scripts/ci/integration/guard.sh
source "$HERE/guard.sh"
created=false
port_pid=""
cleanup() {
  local status=$?
  trap - EXIT
  set +e
  [[ -z "$port_pid" ]] || kill "$port_pid" 2>/dev/null
  if [[ "$created" == true ]]; then
    # Whitelist diagnostics: no pod logs, Secret objects, env, or kubeconfig.
    ci_kube get pods -A -o wide >"$ARTIFACTS/pods.txt" 2>&1
    ci_kube get pods -A -o json | jq '[.items[] | {
      namespace:.metadata.namespace, name:.metadata.name,
      waiting:[.status.containerStatuses[]? | select(.state.waiting != null) |
        {name,reason:.state.waiting.reason,message:.state.waiting.message}]}]' >"$ARTIFACTS/image-pulls.json"
    ci_kube get events -A -o custom-columns='NAMESPACE:.metadata.namespace,REASON:.reason,TYPE:.type,OBJECT:.involvedObject.name,MESSAGE:.message' >"$ARTIFACTS/events.txt" 2>&1
    ci_kube -n argocd get applications -o json | jq '[.items[] | {
      name:.metadata.name, sync:.status.sync.status, health:.status.health.status,
      revisions:.status.sync.revisions, phase:.status.operationState.phase,
      conditions:[.status.conditions[]? | {type:.type}]}]' >"$ARTIFACTS/applications.json"
    # guardrails: allow-live-mutation — delete only the unique Kind cluster created by this invocation.
    kind delete cluster --name "$CLUSTER" >"$ARTIFACTS/cleanup.txt" 2>&1
    if [[ $? -ne 0 ]]; then status=1; echo "Kind cleanup failed: $CLUSTER" >&2; fi
  fi
  rm -rf "$TASK_TMP"
  printf '{"mode":"%s","base":"%s","candidate":"%s","exitCode":%s}\n' \
    "$MODE" "$BASE" "$CANDIDATE" "$status" >"$ARTIFACTS/result.json"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
ci_runtime_guard

age-keygen -o "$SOPS_AGE_KEY_FILE" 2>"$TASK_TMP/age-keygen.log"
recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
mkdir -p "$TASK_TMP/public" "$TASK_TMP/git"
git -C "$TASK_TMP/git" init -q
git -C "$TASK_TMP/git" config user.name 'CI pilot'
git -C "$TASK_TMP/git" config user.email 'ci@example.invalid'
prepare_phase() {
  local label="$1" revision="$2"
  mkdir "$TASK_TMP/$label-source" "$TASK_TMP/$label"
  git archive "$revision" | tar -x -C "$TASK_TMP/$label-source"
  python3 "$HERE/prepare.py" prepare "$TASK_TMP/$label-source" "$TASK_TMP/$label" "$revision" --recipient "$recipient"
  cp "$TASK_TMP/$label/provenance.json" "$ARTIFACTS/$label-provenance.json"
  # Only generated, sanitized resources enter the served Git repository.
  git -C "$TASK_TMP/git" rm -r --ignore-unmatch . >/dev/null
  cp -r "$TASK_TMP/$label/." "$TASK_TMP/git/"
  git -C "$TASK_TMP/git" add .
  git -C "$TASK_TMP/git" commit -qm "$label source $revision"
  git -C "$TASK_TMP/git" rev-parse HEAD >"$TASK_TMP/$label-revision"
}
[[ "$MODE" != upgrade ]] || prepare_phase base "$BASE"
prepare_phase candidate "$CANDIDATE"
git clone -q --bare "$TASK_TMP/git" "$TASK_TMP/public/pilot.git"
git -C "$TASK_TMP/public/pilot.git" update-server-info
chmod 755 "$TASK_TMP"
chmod -R a+rX "$TASK_TMP/public"
python3 - "$TASK_TMP" <<'PY' >"$TASK_TMP/kind.yaml"
import sys, yaml
print(yaml.safe_dump({"kind":"Cluster", "apiVersion":"kind.x-k8s.io/v1alpha4", "nodes":[{
    "role":"control-plane", "extraMounts":[{"hostPath":sys.argv[1]+"/public",
    "containerPath":"/ci-git", "readOnly":True}]}]}))
PY
# Official Kind v0.32.0 node image; keep aligned with scripts/ci/config.json.
# https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0
NODE_IMAGE=kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
existing_clusters="$(kind get clusters)"
if rg -Fxq "$CLUSTER" <<<"$existing_clusters"; then
  echo "Refusing to reuse existing Kind cluster $CLUSTER" >&2; exit 1
fi
created=true # include failed/partial cluster creation in cleanup
# guardrails: allow-live-mutation — Kind creates a new local container cluster, never an existing context.
kind create cluster --name "$CLUSTER" --kubeconfig "$CI_KUBECONFIG" --image "$NODE_IMAGE" --config "$TASK_TMP/kind.yaml" --wait 180s
CI_SERVER="$(kubectl --kubeconfig "$CI_KUBECONFIG" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
ci_guard
ci_kube create namespace argocd # guardrails: allow-live-mutation
ci_kube -n argocd create secret generic argocd-sops-age --from-file="keys.txt=$SOPS_AGE_KEY_FILE" # guardrails: allow-live-mutation
ci_kube apply -f - <<'YAML' # guardrails: allow-live-mutation
apiVersion: apps/v1
kind: Deployment
metadata: {name: ci-git, namespace: argocd}
spec:
  replicas: 1
  selector: {matchLabels: {app: ci-git}}
  template:
    metadata: {labels: {app: ci-git}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: http
          image: busybox:1.37.0
          command: [httpd, -f, -p, "8080", -h, /repo]
          ports: [{containerPort: 8080}]
          resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
          securityContext: {readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
          volumeMounts: [{name: git, mountPath: /repo, readOnly: true}]
      volumes: [{name: git, hostPath: {path: /ci-git, type: Directory}}]
---
apiVersion: v1
kind: Service
metadata: {name: ci-git, namespace: argocd}
spec: {selector: {app: ci-git}, ports: [{port: 8080, targetPort: 8080}]}
YAML
ci_kube -n argocd rollout status deployment/ci-git --timeout=180s

check_app_data() {
  local url="$1" label="$2" team_id media_id
  local -a auth=(-H 'Authorization: Bearer ci-only-bootstrap-token')
  if [[ "$MODE" == install || "$label" == base ]]; then
    # Writes target only the disposable port-forward and synthetic identity.
    curl --fail --silent --show-error --max-time 30 "${auth[@]}" \
      -H 'Content-Type: application/json' --data '{"name":"CI upgrade persistence"}' \
      "$url/v1/teams" >"$TASK_TMP/team.json"
    team_id="$(jq -er '.id' "$TASK_TMP/team.json")"
    printf 'CI media must survive the upgrade\n' >"$TASK_TMP/media.txt"
    curl --fail --silent --show-error --max-time 30 "${auth[@]}" \
      --form "file=@$TASK_TMP/media.txt;type=text/plain" \
      "$url/v1/teams/$team_id/media" >"$TASK_TMP/media.json"
  fi
  team_id="$(jq -er '.id' "$TASK_TMP/team.json")"
  media_id="$(jq -er '.id' "$TASK_TMP/media.json")"
  curl --fail --silent --show-error --max-time 30 "${auth[@]}" "$url/v1/teams" \
    | jq -e --arg id "$team_id" '.items | any(.id == $id and .name == "CI upgrade persistence")' >/dev/null
  curl --fail --silent --show-error --max-time 30 "${auth[@]}" \
    "$url/v1/teams/$team_id/media/$media_id/preview" >"$TASK_TMP/retrieved-media.txt"
  cmp "$TASK_TMP/media.txt" "$TASK_TMP/retrieved-media.txt"
}

install_control_plane() {
  local label="$1" component version repo chart namespace redis_image
  for component in argocd cnpg; do
    version="$(jq -r ".${component}Chart.version" "$TASK_TMP/$label/provenance.json")"
    repo="$(jq -r ".${component}Chart.repo" "$TASK_TMP/$label/provenance.json")"
    chart="$(jq -r ".${component}Chart.name" "$TASK_TMP/$label/provenance.json")"
    namespace=argocd; [[ "$component" != cnpg ]] || namespace=cnpg-system
    if [[ "$component" == argocd ]]; then
      # Resolve the exact chart-selected Redis image. Pull on the local runtime
      # with bounded retries, then load it into Kind before Helm waits for it.
      helm template "$component" "$chart" --repo "$repo" --version "$version" \
        --namespace "$namespace" --values "$TASK_TMP/$label/$component-values.yaml" >"$TASK_TMP/bootstrap.yaml"
      redis_image="$(yq eval -r 'select(.kind == "Deployment" and .metadata.name == "argocd-redis") | .spec.template.spec.containers[] | .image' "$TASK_TMP/bootstrap.yaml")"
      [[ -n "$redis_image" && "$redis_image" != *$'\n'* ]] || { echo 'Expected exactly one Redis bootstrap image' >&2; return 1; }
      ci_preload_image "$redis_image" "$CLUSTER"
    fi
    ci_helm upgrade --install "$component" "$chart" --repo "$repo" --version "$version" \
      --namespace "$namespace" --create-namespace --values "$TASK_TMP/$label/$component-values.yaml" \
      --wait --timeout 8m
  done
  ci_kube wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=120s
}

sync_phase() {
  local label="$1" generated_revision name remaining=120
  generated_revision="$(cat "$TASK_TMP/$label-revision")"
  python3 "$HERE/prepare.py" appset "$TASK_TMP/$label" "$TASK_TMP/$label-appset.yaml" "$generated_revision"
  ci_kube apply -f "$TASK_TMP/$label/app-projects.yaml" # guardrails: allow-live-mutation
  ci_kube apply -f "$TASK_TMP/$label-appset.yaml" # guardrails: allow-live-mutation
  while ((remaining--)); do
    if ci_kube -n argocd get applications -o json | jq -e --arg revision "$generated_revision" '
      [.items[] | select(.metadata.name == "app-gatus" or .metadata.name == "app-goloom")]
      | length == 2 and all(.[];
          .status.sync.status == "Synced" and .status.health.status == "Healthy" and
          ((.status.sync.revisions // [.status.sync.revision]) | index($revision)) != null)
    ' >/dev/null; then break; fi
    sleep 5
  done
  ((remaining >= 0)) || { echo "$label Argo sync did not become Synced/Healthy at $generated_revision" >&2; return 1; }
  for name in gatus goloom; do
    ci_kube -n "$name" rollout status "deployment/$name" --timeout=180s
    ci_kube -n "$name" port-forward "service/$name" "0:$( [[ "$name" == gatus ]] && echo 80 || echo 8080 )" >"$TASK_TMP/forward" 2>&1 &
    port_pid=$!
    for _ in {1..30}; do
      if rg -q 'Forwarding from 127.0.0.1:' "$TASK_TMP/forward"; then break; fi
      sleep 1
    done
    local port path
    port="$(sed -nE 's/Forwarding from 127.0.0.1:([0-9]+).*/\1/p' "$TASK_TMP/forward" | head -1)"
    path=/; [[ "$name" != goloom ]] || path=/healthz
    curl --fail --silent --show-error --retry 5 --retry-connrefused "http://127.0.0.1:$port$path" >/dev/null
    [[ "$name" != goloom ]] || check_app_data "http://127.0.0.1:$port" "$label"
    kill "$port_pid"; wait "$port_pid" || true; port_pid=""
  done
  ci_kube -n goloom get pvc -o json | jq -S '[.items[] | {name:.metadata.name,uid:.metadata.uid}] | sort_by(.name)' >"$ARTIFACTS/$label-pvcs.json"
}

database() {
  local primary
  primary="$(ci_kube -n goloom get cluster goloom-pg -o jsonpath='{.status.currentPrimary}')"
  # Scoped to disposable CI PostgreSQL; current caller reads application state.
  ci_kube -n goloom exec "$primary" -c postgres -- psql -v ON_ERROR_STOP=1 -U postgres -d goloom -Atc "$1" # guardrails: allow-live-mutation
}

if [[ "$MODE" == upgrade ]]; then
  install_control_plane base
  sync_phase base
fi
install_control_plane candidate
sync_phase candidate
if [[ "$MODE" == upgrade ]]; then
  diff -u "$ARTIFACTS/base-pvcs.json" "$ARTIFACTS/candidate-pvcs.json"
fi
# App started against PostgreSQL and created its real application schema/admin.
[[ "$(database "SELECT count(*) FROM users WHERE email = 'ci@example.invalid';")" == 1 ]]
echo "$MODE pilot passed for $CANDIDATE"
