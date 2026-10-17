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
probe_config_map='[select(.kind == "ConfigMap" and (.metadata.name | test("^litellm-network-probe-")))] | .[0]'
ingress='[select(.kind == "Ingress" and .metadata.name == "litellm")] | .[0]'
network_policy='[select(.kind == "CiliumNetworkPolicy" and .metadata.name == "litellm")] | .[0]'
probe_job='[select(.kind == "Job" and .metadata.name == "litellm-network-policy-probe")] | .[0]'
container="$deployment.spec.template.spec.containers[0]"
probe_container="$probe_job.spec.template.spec.containers[0]"
config="($config_map.data[\"config.yaml\"] | from_yaml)"

assert_manifest_eq '[select(.kind == "Deployment")] | length' 1 'expected exactly one Deployment'
assert_manifest_eq '[select(.kind == "Service")] | length' 1 'expected exactly one Service'
assert_manifest_eq '[select(.kind == "Namespace")] | length' 1 'expected exactly one Namespace'
assert_manifest_eq '[select(.kind == "ConfigMap")] | length' 2 'expected exactly two ConfigMaps'
assert_manifest_eq '[select(.kind == "Ingress")] | length' 1 'expected exactly one Ingress'
assert_manifest_eq '[select(.kind == "CiliumNetworkPolicy")] | length' 1 'expected exactly one CiliumNetworkPolicy'
assert_manifest_eq '[select(.kind == "Job")] | length' 1 'expected exactly one probe Job'
assert_manifest_eq '[select(.kind != "Secret")] | length' 8 'unexpected non-Secret runtime resource rendered'
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
assert_manifest_eq "$config.router_settings.disable_cooldowns" true 'router cooldowns must be disabled'
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
assert_manifest_eq "$deployment.spec.template.metadata.annotations[\"litellm.jit.land/secret-revision\"]" v2 'pod must carry secret revision v2'
assert_manifest_eq "$deployment.spec.template.spec.automountServiceAccountToken" false 'service account token automount must be disabled'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsNonRoot" true 'pod must require non-root execution'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsUser" 65534 'pod UID must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.runAsGroup" 65534 'pod GID must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.fsGroup" 65534 'pod fsGroup must be 65534'
assert_manifest_eq "$deployment.spec.template.spec.securityContext.seccompProfile.type" RuntimeDefault 'pod seccomp profile must be RuntimeDefault'
assert_manifest_eq "$deployment.spec.template.metadata.labels[\"network-policy.jit.land/identity\"]" litellm 'server must carry the shared network-policy identity'
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
assert_manifest_eq "$service.spec.selector | keys | sort | join(\",\")" 'app.kubernetes.io/component,app.kubernetes.io/name' 'Service selector must not include the shared probe policy label'
assert_manifest_eq "$service.spec.selector[\"app.kubernetes.io/name\"]" litellm 'Service name selector is wrong'
assert_manifest_eq "$service.spec.selector[\"app.kubernetes.io/component\"]" server 'Service must select only the server component'
assert_manifest_eq "$service.spec.ports | length" 1 'Service must expose one port'
assert_manifest_eq "$service.spec.ports[0].port" 4000 'Service port must be 4000'
assert_manifest_eq "$service.spec.ports[0].targetPort" http 'Service target must use the named port'

assert_manifest_eq "$ingress.spec.ingressClassName" nginx 'Ingress class must be nginx'
assert_manifest_eq "$ingress.spec.rules | length" 1 'Ingress must define exactly one host rule'
assert_manifest_eq "$ingress.spec.rules[0].host" litellm.jit.services 'Ingress host is wrong'
assert_manifest_eq "$ingress.spec.rules[0].http.paths | map(.path + \":\" + .pathType) | sort | join(\",\")" '/v1/chat/completions:Exact,/v1/models:Exact' 'Ingress paths must be the exact public API pair'
assert_manifest_eq "$ingress.spec.rules[0].http.paths | map(.backend.service.name + \":\" + (.backend.service.port.number | tostring)) | unique | join(\",\")" 'litellm:4000' 'Ingress backends must target only litellm:4000'
assert_manifest_eq "$ingress.spec.tls | length" 1 'Ingress must define exactly one TLS entry'
assert_manifest_eq "$ingress.spec.tls[0].hosts | join(\",\")" litellm.jit.services 'Ingress TLS host is wrong'
assert_manifest_eq "$ingress.spec.tls[0].secretName" litellm-tls 'Ingress TLS Secret is wrong'
assert_manifest_eq "$ingress.metadata.annotations | keys | sort | join(\",\")" 'cert-manager.io/cluster-issuer,nginx.org/client-max-body-size,nginx.org/limit-req-burst,nginx.org/limit-req-key,nginx.org/limit-req-no-delay,nginx.org/limit-req-rate,nginx.org/location-snippets,nginx.org/ssl-redirect' 'Ingress annotations must contain only the approved controls'
assert_manifest_eq "$ingress.metadata.annotations[\"cert-manager.io/cluster-issuer\"]" letsencrypt-prod 'Ingress issuer is wrong'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/ssl-redirect\"]" true 'Ingress must redirect HTTP to HTTPS'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/client-max-body-size\"]" 1m 'Ingress body limit must be 1 MiB'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/limit-req-rate\"]" 30r/m 'Ingress rate must be 30 requests per minute'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/limit-req-burst\"]" 10 'Ingress burst must be ten'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/limit-req-no-delay\"]" true 'Ingress burst must not delay requests'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/limit-req-key\"]" '${realip_remote_addr}' 'Ingress rate key must use the trusted real peer'
expected_location_snippets='if ($realip_remote_addr != 192.168.2.37) {
  return 403;
}
set $litellm_route_allowed 0;
set $litellm_route_key "$request_method:$uri";
if ($litellm_route_key = "POST:/v1/chat/completions") {
  set $litellm_route_allowed 1;
}
if ($litellm_route_key = "GET:/v1/models") {
  set $litellm_route_allowed 1;
}
if ($litellm_route_allowed = 0) {
  return 405;
}'
assert_manifest_eq "$ingress.metadata.annotations[\"nginx.org/location-snippets\"]" "$expected_location_snippets" 'Ingress source and method snippet must match the reviewed policy exactly'

assert_manifest_eq "$network_policy.apiVersion" cilium.io/v2 'network policy API version is wrong'
assert_manifest_eq "$network_policy.metadata.namespace" litellm 'network policy namespace is wrong'
assert_manifest_eq "$network_policy.spec | keys | sort | join(\",\")" 'egress,endpointSelector,ingress' 'network policy contains unexpected rule sections'
assert_manifest_eq "$network_policy.spec.endpointSelector | keys | join(\",\")" matchLabels 'network policy endpoint selector contains unexpected expressions'
assert_manifest_eq "$network_policy.spec.endpointSelector.matchLabels | keys | join(\",\")" network-policy.jit.land/identity 'network policy must select only the shared identity'
assert_manifest_eq "$network_policy.spec.endpointSelector.matchLabels[\"network-policy.jit.land/identity\"]" litellm 'network policy identity is wrong'
assert_manifest_eq "$network_policy.spec.ingress | length" 1 'network policy must define one ingress rule'
assert_manifest_eq "$network_policy.spec.ingress[0] | keys | sort | join(\",\")" 'fromEndpoints,toPorts' 'network policy ingress contains unexpected selectors'
assert_manifest_eq "$network_policy.spec.ingress[0].fromEndpoints | length" 1 'network policy ingress must define one source selector'
assert_manifest_eq "$network_policy.spec.ingress[0].fromEndpoints[0] | keys | join(\",\")" matchLabels 'ingress source selector contains unexpected expressions'
assert_manifest_eq "$network_policy.spec.ingress[0].fromEndpoints[0].matchLabels | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" 'k8s:app.kubernetes.io/instance=nginx-ingress,k8s:app.kubernetes.io/name=nginx-ingress,k8s:io.kubernetes.pod.namespace=ingress-nginx' 'ingress-controller selector is wrong'
assert_manifest_eq "$network_policy.spec.ingress[0].toPorts | length" 1 'network policy ingress must define one port rule'
assert_manifest_eq "$network_policy.spec.ingress[0].toPorts[0] | keys | join(\",\")" ports 'network policy ingress port rule contains unexpected fields'
assert_manifest_eq "$network_policy.spec.ingress[0].toPorts[0].ports | length" 1 'network policy ingress must define one port'
assert_manifest_eq "$network_policy.spec.ingress[0].toPorts[0].ports[0] | keys | sort | join(\",\")" 'port,protocol' 'network policy ingress port contains a range or unexpected fields'
assert_manifest_eq "$network_policy.spec.ingress[0].toPorts[0].ports | map(.port + \"/\" + .protocol) | join(\",\")" '4000/TCP' 'network policy ingress must allow only TCP/4000'
assert_manifest_eq "$network_policy.spec.egress | length" 2 'network policy must define exactly DNS and Blablador egress'
assert_manifest_eq "$network_policy.spec.egress[0] | keys | sort | join(\",\")" 'toEndpoints,toPorts' 'DNS egress contains unexpected selectors'
assert_manifest_eq "$network_policy.spec.egress[0].toEndpoints | length" 1 'DNS egress must define one endpoint selector'
assert_manifest_eq "$network_policy.spec.egress[0].toEndpoints[0] | keys | join(\",\")" matchLabels 'DNS endpoint selector contains unexpected expressions'
assert_manifest_eq "$network_policy.spec.egress[0].toEndpoints[0].matchLabels | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" 'k8s:io.kubernetes.pod.namespace=kube-system,k8s:k8s-app=kube-dns' 'kube-dns selector is wrong'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts | length" 1 'DNS egress must define one port rule'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0] | keys | sort | join(\",\")" 'ports,rules' 'DNS port rule contains unexpected fields'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].ports | length" 2 'DNS egress must define exactly TCP and UDP'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].ports | map(keys | sort | join(\"+\")) | unique | join(\",\")" 'port+protocol' 'DNS ports contain ranges or unexpected fields'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].ports | map(.port + \"/\" + .protocol) | sort | join(\",\")" '53/TCP,53/UDP' 'DNS egress must allow TCP and UDP port 53 only'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].rules | keys | join(\",\")" dns 'DNS rule contains unexpected L7 protocols'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].rules.dns | length" 1 'DNS egress must define one exact name'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].rules.dns[0] | keys | join(\",\")" matchName 'DNS rule must not contain wildcard or unexpected fields'
assert_manifest_eq "$network_policy.spec.egress[0].toPorts[0].rules.dns[0].matchName" api.blablador.fz-juelich.de 'DNS egress name is wrong'
assert_manifest_eq "$network_policy.spec.egress[1] | keys | sort | join(\",\")" 'toFQDNs,toPorts' 'HTTPS egress contains unexpected selectors'
assert_manifest_eq "$network_policy.spec.egress[1].toFQDNs | length" 1 'HTTPS egress must define one exact FQDN'
assert_manifest_eq "$network_policy.spec.egress[1].toFQDNs[0] | keys | join(\",\")" matchName 'wildcard FQDN selectors are forbidden'
assert_manifest_eq "$network_policy.spec.egress[1].toFQDNs[0].matchName" api.blablador.fz-juelich.de 'HTTPS egress FQDN is wrong'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts | length" 1 'HTTPS egress must define one port rule'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0] | keys | sort | join(\",\")" 'ports,serverNames' 'HTTPS port rule contains unexpected fields'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0].ports | length" 1 'HTTPS egress must define one port'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0].ports[0] | keys | sort | join(\",\")" 'port,protocol' 'HTTPS port contains a range or unexpected fields'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0].ports | map(.port + \"/\" + .protocol) | join(\",\")" '443/TCP' 'HTTPS egress must allow only TCP/443'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0].serverNames | length" 1 'HTTPS egress must define one SNI'
assert_manifest_eq "$network_policy.spec.egress[1].toPorts[0].serverNames | join(\",\")" api.blablador.fz-juelich.de 'HTTPS egress SNI must match the exact FQDN'

assert_manifest_eq "$probe_config_map.data | keys | join(\",\")" network_probe.py 'probe ConfigMap must contain only network_probe.py'
assert_manifest_eq "$probe_job.metadata.annotations[\"argocd.argoproj.io/hook\"]" PostSync 'probe Job must be an ArgoCD PostSync hook'
assert_manifest_eq "$probe_job.metadata.annotations[\"argocd.argoproj.io/hook-delete-policy\"]" 'BeforeHookCreation,HookSucceeded' 'probe Job must replace stale failures and delete only after success'
assert_manifest_eq "$probe_job.spec | keys | sort | join(\",\")" 'activeDeadlineSeconds,backoffLimit,template' 'probe Job spec contains unexpected controls'
assert_manifest_eq "$probe_job.spec.backoffLimit" 0 'probe Job must not retry'
assert_manifest_eq "$probe_job.spec.activeDeadlineSeconds" 60 'probe Job must have a finite active deadline'
assert_manifest_eq "$probe_job.spec.template.metadata.labels[\"network-policy.jit.land/identity\"]" litellm 'probe must carry the shared network-policy identity'
assert_manifest_eq "$probe_job.spec.template.metadata.labels[\"app.kubernetes.io/component\"]" network-policy-probe 'probe must have a distinct component label'
assert_manifest_eq "$probe_job.spec.template.metadata.labels | keys | sort | join(\",\")" 'app.kubernetes.io/component,app.kubernetes.io/name,network-policy.jit.land/identity' 'probe pod labels contain unexpected selectors'
assert_manifest_eq "$probe_job.spec.template.spec | keys | sort | join(\",\")" 'automountServiceAccountToken,containers,restartPolicy,securityContext,volumes' 'probe pod spec contains unexpected init containers or credential sources'
assert_manifest_eq "$probe_job.spec.template.spec.automountServiceAccountToken" false 'probe must not mount a service account token'
assert_manifest_eq "$probe_job.spec.template.spec.restartPolicy" Never 'probe Job restart policy must be Never'
assert_manifest_eq "$probe_job.spec.template.spec.securityContext.runAsNonRoot" true 'probe must require non-root execution'
assert_manifest_eq "$probe_job.spec.template.spec.securityContext.runAsUser" 65534 'probe UID must be 65534'
assert_manifest_eq "$probe_job.spec.template.spec.securityContext.runAsGroup" 65534 'probe GID must be 65534'
assert_manifest_eq "$probe_job.spec.template.spec.securityContext.fsGroup" 65534 'probe fsGroup must be 65534'
assert_manifest_eq "$probe_job.spec.template.spec.securityContext.seccompProfile.type" RuntimeDefault 'probe seccomp profile must be RuntimeDefault'
assert_manifest_eq "$probe_job.spec.template.spec.containers | length" 1 'probe Job must not contain sidecars'
assert_manifest_eq "$probe_container | keys | sort | join(\",\")" 'command,image,name,resources,securityContext,volumeMounts' 'probe container contains unexpected credential or runtime fields'
assert_manifest_eq "$probe_container.image" "$image_ref" 'probe image must match image-ref.txt exactly'
assert_manifest_eq "$probe_container.command | join(\",\")" 'python3,/probe/network_probe.py' 'probe command is wrong'
assert_manifest_eq "($probe_container | (has(\"env\") or has(\"envFrom\")))" false 'probe must not receive environment credentials'
assert_manifest_eq "$probe_container.resources.requests.cpu" 250m 'probe CPU request must match the server'
assert_manifest_eq "$probe_container.resources.requests.memory" 512Mi 'probe memory request must match the server'
assert_manifest_eq "$probe_container.resources.limits.cpu" 1 'probe CPU limit must match the server'
assert_manifest_eq "$probe_container.resources.limits.memory" 1Gi 'probe memory limit must match the server'
assert_manifest_eq "$probe_container.securityContext.allowPrivilegeEscalation" false 'probe privilege escalation must be disabled'
assert_manifest_eq "$probe_container.securityContext.readOnlyRootFilesystem" true 'probe root filesystem must be read-only'
assert_manifest_eq "$probe_container.securityContext.capabilities.drop | sort | join(\",\")" ALL 'probe must drop all Linux capabilities'
assert_manifest_eq "$probe_container.volumeMounts | map(.mountPath + \":\" + ((.readOnly // false) | tostring)) | sort | join(\",\")" '/probe:true,/tmp:false' 'probe mounts must be read-only code plus bounded /tmp'
assert_manifest_eq "$probe_job.spec.template.spec.volumes | map(.name) | sort | join(\",\")" 'probe,tmp' 'probe must define only code and /tmp volumes'
assert_manifest_eq "$probe_job.spec.template.spec.volumes[] | select(.name == \"probe\") | keys | sort | join(\",\")" 'configMap,name' 'probe code volume must contain only its ConfigMap source'
assert_manifest_eq "$probe_job.spec.template.spec.volumes[] | select(.name == \"probe\") | .configMap.name | test(\"^litellm-network-probe-\")" true 'probe must mount the dedicated generated ConfigMap'
assert_manifest_eq "$probe_job.spec.template.spec.volumes[] | select(.name == \"tmp\") | keys | sort | join(\",\")" 'emptyDir,name' 'probe /tmp volume must contain only bounded emptyDir'
assert_manifest_eq "$probe_job.spec.template.spec.volumes[] | select(.name == \"tmp\") | .emptyDir.sizeLimit" 64Mi 'probe /tmp must be limited to 64Mi'
assert_manifest_eq "[$probe_job.spec.template.spec.volumes[] | select(has(\"secret\"))] | length" 0 'probe must not mount Secrets'

assert_source_eq apps/overlays/main/cluster-config.yaml '.data.host_litellm' litellm.jit.services 'cluster hostname inventory is missing LiteLLM'
assert_source_eq apps/overlays/main/litellm/kustomization.yaml '.resources | join(",")' ../../../base/litellm 'LiteLLM overlay must contain only the base'

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
