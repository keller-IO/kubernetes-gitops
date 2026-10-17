#!/usr/bin/env bash

set -euo pipefail

command -v yq >/dev/null

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/ci/check-sops.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

cat >"$fixture_dir/duplicate.sops.yaml" <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: duplicate-payload-key
data:
  SHARED_KEY: cGxhaW50ZXh0
stringData:
  SHARED_KEY: ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]
sops:
  mac: ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]
EOF

if output="$("$checker" "$fixture_dir" 2>&1)"; then
  printf 'Expected duplicate Secret payload keys to fail\n' >&2
  exit 1
fi

grep -Fq "DUPLICATE PAYLOAD KEY: $fixture_dir/duplicate.sops.yaml: SHARED_KEY" <<<"$output"
