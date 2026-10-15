#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail=0

while IFS= read -r file; do
  states="$(yq eval -r '
    ((.data // {}) * (.stringData // {})) as $payload |
    (((.sops.mac // "") | test("^ENC\\[AES256_GCM,"))) as $encrypted_metadata |
    [
      ($encrypted_metadata and
       ([$payload[] | (tag == "!!str" and (test("^ENC\\[AES256_GCM,") or . == ""))] | all)),
      (($encrypted_metadata | not) and ($payload | length) > 0 and
       ([$payload[] | (tag == "!!str" and test("^(REPLACE_ME|CHANGE ME|PLACEHOLDER|placeholder|age1placeholder)$"))] | all))
    ] | @tsv
  ' "$file")"

  if grep -qx $'false\tfalse' <<<"$states"; then
    printf 'UNENCRYPTED: %s\n' "$file" >&2
    fail=1
  elif grep -qx $'false\ttrue' <<<"$states"; then
    printf 'WARN placeholder secret not encrypted yet: %s\n' "$file"
  fi
done < <(find apps infrastructure clusters -name '*.sops.yaml' -type f -print)

exit "$fail"
