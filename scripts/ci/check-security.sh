#!/usr/bin/env bash
# Blocks new HIGH/CRITICAL misconfigurations and all detected real secrets.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="${1:?Usage: check-security.sh RENDERED_DIRECTORY}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
checks="$(jq -er '.checksBundle' "$repo_root/scripts/ci/security-config.json")"
trivy config --checks-bundle-repository "$checks" --format json --severity HIGH,CRITICAL --output "$work/config.json" "$rendered"
python3 "$repo_root/scripts/ci/check-security.py" "$work/config.json" \
  "$repo_root/scripts/ci/known-gaps/security.json"
# Temp renders contain synthetic credentials only; scan tracked source without
# generated agent configs, chart caches, or local worktrees.
trivy fs --scanners secret --severity HIGH,CRITICAL --exit-code 1 \
  --skip-dirs .git --skip-dirs .agents --skip-dirs .claude --skip-dirs .codex \
  --skip-dirs .cursor --skip-dirs .opencode --skip-dirs .worktrees \
  --skip-dirs .artifacts \
  --skip-dirs '**/charts' "$repo_root"
