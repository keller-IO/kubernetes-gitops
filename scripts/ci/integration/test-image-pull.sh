#!/usr/bin/env bash
# Exercise network retries at the actual runtime boundary without a cluster.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/ci/integration/guard.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export KIND_EXPERIMENTAL_PROVIDER=docker
ci_runtime_guard() { return 0; } # identity/runtime rejection tested by test-guards.sh
sleep() { :; }
docker() {
  [[ "$*" == 'pull registry.example/redis:1' ]] || return 1
  count="$(cat "$work/count")"
  echo "$((count + 1))" >"$work/count"
  [[ "$count" -ge "$failures" ]]
}
kind() {
  [[ "$*" == 'load docker-image --name keller-ci-fixture registry.example/redis:1' ]] || return 1
  echo loaded >>"$work/loads"
}
echo 0 >"$work/count"
failures=2
ci_preload_image registry.example/redis:1 keller-ci-fixture
[[ "$(cat "$work/count")" == 3 && "$(wc -l <"$work/loads")" == 1 ]]
echo 0 >"$work/count"
rm "$work/loads"
failures=3
if ci_preload_image registry.example/redis:1 keller-ci-fixture; then
  echo 'ERROR permanent pull failure was ignored' >&2; exit 1
fi
[[ "$(cat "$work/count")" == 3 && ! -f "$work/loads" ]]
if ci_preload_image registry.example/redis:1 production; then
  echo 'ERROR non-CI cluster was accepted' >&2; exit 1
fi
echo 'Transient pulls recover; permanent failures and non-CI targets fail closed.'
