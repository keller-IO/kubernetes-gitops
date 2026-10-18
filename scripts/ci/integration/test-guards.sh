#!/usr/bin/env bash
# Exercise the write boundary without any cluster or real kubeconfig.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
mkdir "$TASK_TMP/bin"
cat >"$TASK_TMP/bin/kubectl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'config view --minify -o json'* ]]; then
  cat "$FAKE_IDENTITY"
else
  printf '%s\n' "$*" >>"$FAKE_CALLS"
fi
SH
chmod +x "$TASK_TMP/bin/kubectl"
cp "$TASK_TMP/bin/kubectl" "$TASK_TMP/bin/helm"
export PATH="$TASK_TMP/bin:$PATH"
export FAKE_IDENTITY="$TASK_TMP/identity.json" FAKE_CALLS="$TASK_TMP/calls"
export CI_KUBECONFIG="$TASK_TMP/kubeconfig" KUBECONFIG="$TASK_TMP/kubeconfig"
export CI_CONTEXT=kind-keller-ci-unit CI_SERVER=https://127.0.0.1:12345
identity() {
  jq -n --arg context "$1" --arg server "$2" '{"current-context":$context,
    contexts:[{context:{cluster:$context}}],clusters:[{cluster:{server:$server}}]}' >"$FAKE_IDENTITY"
}
# shellcheck source=scripts/ci/integration/guard.sh
source "$HERE/guard.sh"
identity "$CI_CONTEXT" "$CI_SERVER"
ci_guard
ci_kube get namespaces
[[ "$(cat "$FAKE_CALLS")" == "--kubeconfig $CI_KUBECONFIG --context $CI_CONTEXT get namespaces" ]]
reject() {
  if ci_guard >"$TASK_TMP/stdout" 2>"$TASK_TMP/stderr"; then
    echo "Guard incorrectly accepted $1" >&2; exit 1
  fi
}
CI_SERVER="" reject missing_identity
CI_CONTEXT=production reject production_context
KUBECONFIG="$TASK_TMP/other" reject swapped_config
identity production "$CI_SERVER"
reject renamed_context
identity "$CI_CONTEXT" https://prod.example.invalid:6443
reject remote_server
CI_SERVER=https://prod.example.invalid:6443 reject remote_server_even_if_expected
identity "$CI_CONTEXT" https://127.0.0.1:54321
reject swapped_local_cluster
rm "$FAKE_CALLS"
if ci_kube apply -f forbidden.yaml 2>"$TASK_TMP/stderr"; then # guardrails: allow-live-mutation — fake kubectl, wrong-context negative.
  echo 'Wrapper ignored a rejected guard in a conditional' >&2; exit 1
fi
[[ ! -e "$FAKE_CALLS" ]] || { echo 'Rejected wrapper called kubectl' >&2; exit 1; }
if ci_helm upgrade forbidden forbidden 2>"$TASK_TMP/stderr"; then
  echo 'Helm wrapper ignored a rejected guard in a conditional' >&2; exit 1
fi
[[ ! -e "$FAKE_CALLS" ]] || { echo 'Rejected wrapper called Helm' >&2; exit 1; }
echo 'Context guards: positive case, 7 identity rejections and both conditional write wrappers passed'

cat >"$TASK_TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == context ]]; then printf '%s\n' "$FAKE_DOCKER_ENDPOINT"; else echo 28.0.0; fi
SH
cat >"$TASK_TMP/bin/podman" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '{"host":{"serviceIsRemote":%s}}\n' "$FAKE_PODMAN_REMOTE"
SH
chmod +x "$TASK_TMP/bin/docker" "$TASK_TMP/bin/podman"
unset DOCKER_HOST DOCKER_CONTEXT CONTAINER_HOST CONTAINER_CONNECTION
export FAKE_DOCKER_ENDPOINT=unix:///var/run/docker.sock FAKE_PODMAN_REMOTE=false
KIND_EXPERIMENTAL_PROVIDER=docker ci_runtime_guard
KIND_EXPERIMENTAL_PROVIDER=podman ci_runtime_guard
reject_runtime() {
  if ci_runtime_guard >"$TASK_TMP/stdout" 2>"$TASK_TMP/stderr"; then
    echo "Runtime guard incorrectly accepted $1" >&2; exit 1
  fi
}
KIND_EXPERIMENTAL_PROVIDER=docker DOCKER_HOST=tcp://prod.example.invalid:2376 reject_runtime docker_host
KIND_EXPERIMENTAL_PROVIDER=docker DOCKER_CONTEXT=production FAKE_DOCKER_ENDPOINT=ssh://prod.example.invalid reject_runtime docker_context
KIND_EXPERIMENTAL_PROVIDER=podman CONTAINER_HOST=ssh://prod.example.invalid reject_runtime podman_host
KIND_EXPERIMENTAL_PROVIDER=podman CONTAINER_CONNECTION=production reject_runtime podman_connection
KIND_EXPERIMENTAL_PROVIDER=podman FAKE_PODMAN_REMOTE=true reject_runtime podman_remote
KIND_EXPERIMENTAL_PROVIDER=nerdctl reject_runtime unknown_provider
echo 'Runtime guards: 2 local providers accepted and 6 remote/unsupported cases rejected'
