#!/usr/bin/env bash
# All writes target this runner's newly created Kind cluster. Cleanup deletes it.
set -euo pipefail

ci_runtime_guard() {
  local endpoint info
  case "${KIND_EXPERIMENTAL_PROVIDER:-docker}" in
    docker)
      if [[ -n "${DOCKER_CONTEXT:-}" ]]; then
        endpoint="$(docker context inspect "$DOCKER_CONTEXT" --format '{{.Endpoints.docker.Host}}')" || return
      elif [[ -n "${DOCKER_HOST:-}" ]]; then
        endpoint="$DOCKER_HOST"
      else
        endpoint="$(docker context inspect --format '{{.Endpoints.docker.Host}}')" || return
      fi
      [[ "$endpoint" == unix:///* ]] || { echo 'Refusing remote Docker endpoint/context' >&2; return 1; }
      docker info --format '{{.ServerVersion}}' >/dev/null || return
      ;;
    podman)
      [[ -z "${CONTAINER_HOST:-}${CONTAINER_CONNECTION:-}" ]] || {
        echo 'Refusing Podman remote connection' >&2; return 1;
      }
      info="$(podman info --format json)" || return
      jq -e '.host.serviceIsRemote == false' <<<"$info" >/dev/null || {
        echo 'Refusing Podman remote service' >&2; return 1;
      }
      ;;
    *) echo 'Only local Docker or local Podman is supported' >&2; return 1 ;;
  esac
}

ci_guard() {
  [[ -n "${CI_KUBECONFIG:-}" && -n "${CI_CONTEXT:-}" && -n "${CI_SERVER:-}" ]] || {
    echo "Missing isolated cluster identity" >&2; return 1;
  }
  [[ "${KUBECONFIG:-}" == "$CI_KUBECONFIG" && "$CI_CONTEXT" == kind-keller-ci-* ]] || {
    echo "Refusing non-CI kubeconfig/context" >&2; return 1;
  }
  local identity
  identity="$(kubectl --kubeconfig "$CI_KUBECONFIG" config view --minify -o json)" || return 1
  jq -e --arg context "$CI_CONTEXT" --arg server "$CI_SERVER" '
    .["current-context"] == $context and
    .contexts[0].context.cluster == $context and
    .clusters[0].cluster.server == $server and
    ($server | test("^https://127\\.0\\.0\\.1:[0-9]+$"))
  ' <<<"$identity" >/dev/null || { echo "Refusing unexpected cluster identity" >&2; return 1; }
}

ci_kube() {
  ci_guard || return
  # guardrails: allow-live-mutation — explicit temporary Kind config and identity checked above.
  kubectl --kubeconfig "$CI_KUBECONFIG" --context "$CI_CONTEXT" "$@" # guardrails: allow-live-mutation
}

ci_helm() {
  ci_guard || return
  # guardrails: allow-live-mutation — Helm can write only to the same temporary Kind cluster.
  helm "$@" --kubeconfig "$CI_KUBECONFIG" --kube-context "$CI_CONTEXT" # guardrails: allow-live-mutation
}
