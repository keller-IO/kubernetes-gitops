#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

rendered="$({
  kustomize build --enable-alpha-plugins --enable-exec apps/base/litellm
} | yq eval '
  (select(.kind == "Secret") | .data[]?) = "REDACTED" |
  (select(.kind == "Secret") | .stringData[]?) = "REDACTED"
' -)"
trap 'unset rendered' EXIT

manifest_query() {
  printf '%s\n' "$rendered" | yq eval-all -r "$1" -
}

assert_manifest_eq() {
  local expression="$1"
  local expected="$2"
  local description="$3"
  local actual
  actual="$(manifest_query "$expression")"
  [[ "$actual" == "$expected" ]] || fail "$description"
}

assert_source_eq() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local description="$4"
  local actual
  actual="$(yq eval -r "$expression" "$file")"
  [[ "$actual" == "$expected" ]] || fail "$description"
}

image_ref="$(<apps/base/litellm/image-ref.txt)"
deployment='[select(.kind == "Deployment" and .metadata.name == "litellm")] | .[0]'
service='[select(.kind == "Service" and .metadata.name == "litellm")] | .[0]'
namespace='[select(.kind == "Namespace" and .metadata.name == "litellm")] | .[0]'
config_map='[select(.kind == "ConfigMap" and (.metadata.name | test("^litellm-config-")))] | .[0]'
container="$deployment.spec.template.spec.containers[0]"
config="($config_map.data[\"config.yaml\"] | from_yaml)"

assert_manifest_eq '[select(.kind == "Deployment")] | length' 1 'expected exactly one Deployment'
assert_manifest_eq '[select(.kind == "Service")] | length' 1 'expected exactly one Service'
assert_manifest_eq '[select(.kind == "Namespace")] | length' 1 'expected exactly one Namespace'
assert_manifest_eq '[select(.kind == "ConfigMap")] | length' 1 'expected exactly one ConfigMap'
assert_manifest_eq '[select(.kind != "Secret")] | length' 4 'unexpected non-Secret runtime resource rendered'
assert_manifest_eq '[select(.kind == "PersistentVolumeClaim" or .kind == "StatefulSet" or .kind == "HorizontalPodAutoscaler" or .kind == "PodDisruptionBudget" or .kind == "ServiceMonitor")] | length' 0 'stateful, autoscaling, disruption-budget, and monitoring resources are forbidden'

assert_manifest_eq "$namespace.metadata.labels[\"pod-security.kubernetes.io/enforce\"]" restricted 'namespace must enforce restricted Pod Security'
assert_manifest_eq "$namespace.metadata.labels[\"pod-security.kubernetes.io/audit\"]" restricted 'namespace must audit restricted Pod Security'
assert_manifest_eq "$namespace.metadata.labels[\"pod-security.kubernetes.io/warn\"]" restricted 'namespace must warn on restricted Pod Security'

assert_manifest_eq "$config_map.data | keys | sort | join(\",\")" 'config.yaml,request_policy.py,request_policy_core.py' 'ConfigMap must contain exactly the runtime config and policy modules'
assert_manifest_eq "$config | keys | sort | join(\",\")" 'general_settings,litellm_settings,model_list,router_settings' 'LiteLLM config must contain only approved top-level sections'
assert_manifest_eq "$config.model_list | length" 1 'LiteLLM must expose exactly one model deployment'
assert_manifest_eq "$config.model_list[0].model_name" hermes-blablador 'public model name must be stable'
assert_manifest_eq "$config.model_list[0] | keys | sort | join(\",\")" 'litellm_params,model_info,model_name' 'model deployment contains unexpected fields'
assert_manifest_eq "$config.model_list[0].model_info.id" hermes-blablador 'deployment ID must be stable'
assert_manifest_eq "$config.model_list[0].model_info.mode" chat 'deployment mode must be chat'
assert_manifest_eq "$config.model_list[0].model_info | keys | sort | join(\",\")" 'id,mode' 'model_info contains unexpected fields'
assert_manifest_eq "$config.model_list[0].litellm_params.model" openai/alias-code 'provider model must be Blablador alias-code'
assert_manifest_eq "$config.model_list[0].litellm_params.api_base" https://api.blablador.fz-juelich.de/v1 'provider API base must be Blablador'
assert_manifest_eq "$config.model_list[0].litellm_params.api_key" os.environ/BLABLADOR_API_KEY 'provider key must come from the environment'
assert_manifest_eq "$config.model_list[0].litellm_params | keys | sort | join(\",\")" 'api_base,api_key,model' 'provider deployment contains unexpected fields'
assert_manifest_eq "$config.router_settings.num_retries" 0 'router retries must be disabled'
assert_manifest_eq "$config.router_settings | keys | sort | join(\",\")" 'disable_cooldowns,num_retries' 'router settings contain unexpected controls'
assert_manifest_eq "($config.router_settings | (has(\"fallbacks\") or has(\"default_fallbacks\") or has(\"context_window_fallbacks\")))" false 'LiteLLM fallbacks are forbidden'
assert_manifest_eq "$config.litellm_settings.callbacks" request_policy.hermes_request_policy 'request policy callback must be registered'
assert_manifest_eq "$config.litellm_settings.drop_params" false 'parameter dropping must be disabled'
assert_manifest_eq "$config.litellm_settings.turn_off_message_logging" true 'message logging must be disabled'
assert_manifest_eq "$config.litellm_settings | keys | sort | join(\",\")" 'callbacks,drop_params,turn_off_message_logging' 'LiteLLM settings contain unexpected callbacks or tracking controls'
assert_manifest_eq "$config.general_settings.master_key" os.environ/LITELLM_MASTER_KEY 'master key must come from the environment'
assert_manifest_eq "$config.general_settings.max_in_flight_requests_per_worker" 4 'in-flight admission limit must be four'
assert_manifest_eq "$config.general_settings.max_queued_requests_per_worker" 4 'queued admission limit must be four'
assert_manifest_eq "$config.general_settings.admission_queue_timeout_seconds" 1 'queue timeout must be one second'
assert_manifest_eq "$config.general_settings | keys | sort | join(\",\")" 'admission_queue_timeout_seconds,master_key,max_in_flight_requests_per_worker,max_queued_requests_per_worker' 'general settings contain unexpected database, Redis, or control-plane configuration'

assert_manifest_eq "$deployment.metadata.annotations[\"argocd.argoproj.io/sync-wave\"]" 0 'Deployment sync wave must be zero'
assert_manifest_eq "$deployment.spec.replicas" 1 'Deployment must have one replica'
assert_manifest_eq "$deployment.spec.strategy.type" Recreate 'Deployment strategy must be Recreate'
assert_manifest_eq "$deployment.spec.template.metadata.annotations[\"litellm.jit.land/secret-revision\"]" v1 'pod must carry secret revision v1'
assert_manifest_eq "$deployment.spec.template.spec.automountServiceAccountToken" false 'service account token automount must be disabled'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsNonRoot" true 'pod must require non-root execution'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsUser" 65534 'pod UID must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsGroup" 65534 'pod GID must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.fsGroup" 65534 'pod fsGroup must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.seccompProfile.type" RuntimeDefault 'pod seccomp profile must be RuntimeDefault'
assert_manifest_eq "$deployment.spec.template.spec.containers | length" 1 'Deployment must not contain sidecars'
assert_manifest_eq "$container.name" litellm 'server container must be named litellm'
assert_manifest_eq "$container.image" "$image_ref" 'Deployment image must match image-ref.txt exactly'
assert_manifest_eq "$container.args | join(\",\")" '--config,/app/config/config.yaml,--port,4000,--num_workers,1' 'LiteLLM arguments must pin config, port, and one worker'
assert_manifest_eq "$container.ports | length" 1 'server must expose one container port'
assert_manifest_eq "$container.ports[0].name" http 'container port must be named http'
assert_manifest_eq "$container.ports[0].containerPort" 4000 'container must listen on port 4000'
assert_manifest_eq "$container.readinessProbe.httpGet.path" /health/readiness 'readiness probe must use the local readiness endpoint'
assert_manifest_eq "$container.readinessProbe.httpGet.port" http 'readiness probe must use the named port'
assert_manifest_eq "$container.livenessProbe.httpGet.path" /health/liveliness 'liveness probe must use the local liveliness endpoint'
assert_manifest_eq "$container.livenessProbe.httpGet.port" http 'liveness probe must use the named port'
assert_manifest_eq "$container.resources.requests.cpu" 250m 'CPU request must be 250m'
assert_manifest_eq "$container.resources.requests.memory" 512Mi 'memory request must be 512Mi'
assert_manifest_eq "$container.resources.limits.cpu" 1 'CPU limit must be one core'
assert_manifest_eq "$container.resources.limits.memory" 1Gi 'memory limit must be 1Gi'
assert_manifest_eq "$container.securityContext.allowPrivilegeEscalation" false 'privilege escalation must be disabled'
assert_manifest_eq "$container.securityContext.readOnlyRootFilesystem" true 'root filesystem must be read-only'
assert_manifest_eq "$container.securityContext.capabilities.drop | sort | join(\",\")" ALL 'all Linux capabilities must be dropped'
assert_manifest_eq "$container.env | map(.name) | sort | join(\",\")" 'BLABLADOR_API_KEY,DISABLE_ADMIN_UI,LITELLM_DONT_SHOW_FEEDBACK_BOX,LITELLM_LOCAL_MODEL_COST_MAP,LITELLM_LOG,LITELLM_MASTER_KEY,LITELLM_MIGRATION_DIR,LITELLM_MODE,NO_DOCS,NO_OPENAPI,NO_REDOC,PYTHONDONTWRITEBYTECODE,XDG_CACHE_HOME' 'container environment must contain only approved settings and two secret references'
assert_manifest_eq "$container.env[] | select(.name == \"BLABLADOR_API_KEY\") | .valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key" 'litellm/BLABLADOR_API_KEY' 'provider key reference is wrong'
assert_manifest_eq "$container.env[] | select(.name == \"LITELLM_MASTER_KEY\") | .valueFrom.secretKeyRef.name + \"/\" + .valueFrom.secretKeyRef.key" 'litellm/LITELLM_MASTER_KEY' 'master key reference is wrong'
assert_manifest_eq "$container.env[] | select(.name == \"LITELLM_MODE\") | .value" PRODUCTION 'LiteLLM mode must be production'
assert_manifest_eq "$container.env[] | select(.name == \"LITELLM_LOCAL_MODEL_COST_MAP\") | .value" True 'local model cost map must be forced'
assert_manifest_eq "$container.env[] | select(.name == \"LITELLM_LOG\") | .value" ERROR 'debug logging must remain disabled'
assert_manifest_eq "$container.env[] | select(.name == \"DISABLE_ADMIN_UI\") | .value" True 'Admin UI must be disabled'
assert_manifest_eq "$container.env[] | select(.name == \"NO_DOCS\" or .name == \"NO_REDOC\" or .name == \"NO_OPENAPI\") | .value" $'True\nTrue\nTrue' 'docs, ReDoc, and OpenAPI must be disabled'
assert_manifest_eq "$container.env | map(select(.name == \"PRISMA_BINARY_CACHE_DIR\" or .name == \"PRISMA_CLI_PATH\")) | length" 0 'image Prisma paths must not be overridden'
assert_manifest_eq "$container.volumeMounts | map(.mountPath) | sort | join(\",\")" '/app/.cache,/app/config,/app/migrations,/tmp' 'container must mount only config and bounded writable paths'
assert_manifest_eq "$container.volumeMounts[] | select(.mountPath == \"/app/config\") | .readOnly" true 'runtime ConfigMap must be mounted read-only'
assert_manifest_eq "$deployment.spec.template.spec.volumes | map(.name) | sort | join(\",\")" 'cache,config,migrations,tmp' 'pod must define only the config and bounded writable volumes'
assert_manifest_eq "$deployment.spec.template.spec.volumes[] | select(.name == \"tmp\") | .emptyDir.sizeLimit" 64Mi '/tmp must be limited to 64Mi'
assert_manifest_eq "$deployment.spec.template.spec.volumes[] | select(.name == \"cache\") | .emptyDir.sizeLimit" 128Mi '/app/.cache must be limited to 128Mi'
assert_manifest_eq "$deployment.spec.template.spec.volumes[] | select(.name == \"migrations\") | .emptyDir.sizeLimit" 64Mi '/app/migrations must be limited to 64Mi'

assert_manifest_eq "$service.spec.type" ClusterIP 'Service must be ClusterIP'
assert_manifest_eq "$service.spec.selector[\"app.kubernetes.io/name\"]" litellm 'Service name selector is wrong'
assert_manifest_eq "$service.spec.selector[\"app.kubernetes.io/component\"]" server 'Service must select only the server component'
assert_manifest_eq "$service.spec.ports | length" 1 'Service must expose one port'
assert_manifest_eq "$service.spec.ports[0].port" 4000 'Service port must be 4000'
assert_manifest_eq "$service.spec.ports[0].targetPort" http 'Service target must use the named port'

secret_file='apps/base/litellm/secret.sops.yaml'
assert_source_eq "$secret_file" '.kind' Secret 'encrypted source must be a Secret'
assert_source_eq "$secret_file" '.metadata.name' litellm 'Secret name is wrong'
assert_source_eq "$secret_file" '.metadata.namespace' litellm 'Secret namespace is wrong'
assert_source_eq "$secret_file" '.metadata.annotations["argocd.argoproj.io/sync-wave"]' -1 'Secret sync wave must be -1'
assert_source_eq "$secret_file" '.type' Opaque 'Secret must be Opaque'
assert_source_eq "$secret_file" '[(.data // {} | keys[]), (.stringData // {} | keys[])] | sort | join(",")' 'BLABLADOR_API_KEY,LITELLM_MASTER_KEY' 'Secret must contain exactly the provider and master keys'
assert_source_eq "$secret_file" '[.stringData[] | test("^ENC\\[AES256_GCM,")] | all' true 'Secret values must be SOPS encrypted'
assert_source_eq "$secret_file" '.sops.mac | test("^ENC\\[AES256_GCM,")' true 'Secret must carry a SOPS MAC'

assert_source_eq apps/base/litellm/kustomization.yaml '.generators | join(",")' ./secret-generator.yaml 'Kustomization must include only the KSOPS generator'
assert_source_eq apps/base/litellm/secret-generator.yaml '.apiVersion' viaduct.ai/v1 'KSOPS generator API version is wrong'
assert_source_eq apps/base/litellm/secret-generator.yaml '.kind' ksops 'Secret generator must use KSOPS'
assert_source_eq apps/base/litellm/secret-generator.yaml '.metadata.annotations["config.kubernetes.io/function"] | from_yaml | .exec.path' ksops 'Secret generator must execute KSOPS'
assert_source_eq apps/base/litellm/secret-generator.yaml '.files | join(",")' ./secret.sops.yaml 'KSOPS generator must reference the encrypted Secret'

rendered_secret_count="$(manifest_query '[select(.kind == "Secret" and .metadata.name == "litellm")] | length')"
ksops_bin="$(command -v ksops)"
expected_secret_count=1
if [[ "$(wc -l <"$ksops_bin")" == 2 ]] && grep -qx 'exit 0' "$ksops_bin"; then
  expected_secret_count=0
fi
[[ "$rendered_secret_count" == "$expected_secret_count" ]] || fail 'KSOPS did not render the expected Secret count'
assert_manifest_eq '[select(.kind == "Secret")] | length' "$expected_secret_count" 'render must contain exactly the expected Secret count'
if [[ "$expected_secret_count" == 1 ]]; then
  assert_manifest_eq '[select(.kind == "Secret" and .metadata.name == "litellm")] | .[0] | [(.data // {} | keys[]), (.stringData // {} | keys[])] | sort | join(",")' 'BLABLADOR_API_KEY,LITELLM_MASTER_KEY' 'rendered Secret keys are wrong'
fi

printf 'LiteLLM manifest checks passed.\n'
