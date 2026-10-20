#!/usr/bin/env bash
# Exercise network retries at the actual runtime boundary without a cluster.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
source "$root/scripts/ci/integration/guard.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export KIND_EXPERIMENTAL_PROVIDER=docker
mirror="docker.io/library/redis@sha256:$(printf 'a%.0s' {1..64})"
jq -n --arg mirror "$mirror" '{"registry.example/redis:1":$mirror}' >"$work/mirrors.json"
ci_runtime_guard() { return 0; } # identity/runtime rejection tested by test-guards.sh
sleep() { :; }
docker() {
  if [[ "$*" == "tag $mirror registry.example/redis:1" ]]; then
    echo tagged >"$work/tagged"; return 0
  fi
  if [[ "$*" == "version -f {{.Server.Os}}/{{.Server.Arch}}" ]]; then
    echo linux/amd64; return 0
  fi
  if [[ $# == 6 && "$1 $2 $3 $4 $6" == "save --platform linux/amd64 -o registry.example/redis:1" ]]; then
    echo archive >"$5"; return 0
  fi
  [[ "$*" == "pull $mirror" ]] || return 1
  count="$(cat "$work/count")"
  echo "$((count + 1))" >"$work/count"
  [[ "$count" -ge "$failures" ]]
}
kind() {
  [[ $# == 5 && "$1 $2 $3 $4" == 'load image-archive --name keller-ci-fixture' && "$(cat "$5")" == archive ]] || return 1
  echo loaded >>"$work/loads"
}
echo 0 >"$work/count"
failures=2
ci_preload_image registry.example/redis:1 keller-ci-fixture "$work/mirrors.json"
[[ "$(cat "$work/count")" == 3 && "$(wc -l <"$work/loads")" == 1 && -f "$work/tagged" ]]
echo 0 >"$work/count"
rm "$work/loads"
failures=3
if ci_preload_image registry.example/redis:1 keller-ci-fixture "$work/mirrors.json"; then
  echo 'ERROR permanent pull failure was ignored' >&2; exit 1
fi
[[ "$(cat "$work/count")" == 3 && ! -f "$work/loads" ]]
if ci_preload_image registry.example/redis:1 production "$work/mirrors.json"; then
  echo 'ERROR non-CI cluster was accepted' >&2; exit 1
fi
if ci_preload_image registry.example/redis:2 keller-ci-fixture "$work/mirrors.json"; then
  echo 'ERROR unreviewed image was accepted' >&2; exit 1
fi
echo '{"registry.example/redis:1":"docker.io/library/redis:latest"}' >"$work/mirrors.json"
if ci_preload_image registry.example/redis:1 keller-ci-fixture "$work/mirrors.json"; then
  echo 'ERROR unpinned mirror was accepted' >&2; exit 1
fi
echo 'Transient pulls recover; permanent failures and non-CI targets fail closed.'
