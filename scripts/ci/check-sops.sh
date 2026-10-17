#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail=0

if (($# > 0)); then
  search_roots=("$@")
else
  search_roots=(apps infrastructure clusters)
fi

while IFS= read -r file; do
  duplicate_keys="$(yq eval -r '
    ((.data // {}) | keys) as $data_keys |
    ((.stringData // {}) | keys) as $string_data_keys |
    ($data_keys + $string_data_keys | group_by(.) | .[] |
     select(length > 1) | .[0])
  ' "$file")"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    printf 'DUPLICATE PAYLOAD KEY: %s: %s\n' "$file" "$key" >&2
    fail=1
  done <<<"$duplicate_keys"

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
done < <(find "${search_roots[@]}" -name '*.sops.yaml' -type f -print)

exit "$fail"
