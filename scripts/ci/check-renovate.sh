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

# A valid regex that extracts no Plan/installer update would silently stop OS updates.
talos_file=infrastructure/base/system-upgrade-controller/talos-plan.yaml
talos_version="$(sed -nE 's/^  version: (v[0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$talos_file")"
jq -e --arg file "$talos_file" --arg version "$talos_version" '
  any(.regex[]?; .packageFile == $file and
    ([.deps[]? | select(.depName == "siderolabs/talos" and .currentValue == $version)] | length == 2)) and
  any(.kubernetes[]?; .packageFile == $file and
    any(.deps[]?; .depName == "ghcr.io/siderolabs/talosctl" and .currentValue == $version))
' "$audit_dir/deps.json" >/dev/null || {
  echo 'Talos Plan, installer and CLI must all be extracted at the same version' >&2
  exit 1
}

# Check every extracted file, without app-specific expected dependencies.
jq -e '
  ([.[][]] | length > 0) and
  all(.[][]; (.packageFile | test("(/charts/|\\.sops\\.yaml$)") | not))
' "$audit_dir/deps.json" >/dev/null

jq -r 'select(.msg == "Dependency extraction complete") | .stats.total |
  "Renovate extraction passed: \(.depCount) dependencies in \(.fileCount) package files."' "$audit_dir/log.jsonl"
