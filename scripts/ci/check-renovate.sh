#!/usr/bin/env bash
# Exercise Renovate's real extractors; schema validation alone misses zero matches.
set -euo pipefail

renovate-config-validator --strict renovate.json
audit_dir="$(mktemp -d)"
trap 'rm -rf "$audit_dir"' EXIT
LOG_FORMAT=json LOG_LEVEL=debug renovate --platform=local --dry-run=extract >"$audit_dir/log.jsonl"

# Renovate can report a repository error while exiting successfully.
jq -se 'all(.[]; .level < 50)' "$audit_dir/log.jsonl" >/dev/null
jq -se '[.[] | select(.msg == "Extracted dependencies") | .packageFiles] | last // error("No extraction result")' \
  "$audit_dir/log.jsonl" >"$audit_dir/deps.json"

# Every CNPG imageName must be extracted, regardless of filename or annotations.
while IFS= read -r file; do
  jq -e --arg file "$file" '
    any(.regex[]?; .packageFile == $file and
      any(.deps[]?; .datasource == "docker" and .depName == "ghcr.io/cloudnative-pg/postgresql"))
  ' "$audit_dir/deps.json" >/dev/null || {
    echo "CNPG image not extracted: $file" >&2
    exit 1
  }
done < <(git grep -l -E '^[[:space:]]*imageName:' -- apps infrastructure clusters ':!*.sops.yaml')

# Check every extracted file, without app-specific expected dependencies.
jq -e '
  ([.[][]] | length > 0) and
  all(.[][]; (.packageFile | test("(/charts/|\\.sops\\.yaml$)") | not))
' "$audit_dir/deps.json" >/dev/null

jq -r 'select(.msg == "Dependency extraction complete") | .stats.total |
  "Renovate extraction passed: \(.depCount) dependencies in \(.fileCount) package files."' "$audit_dir/log.jsonl"
