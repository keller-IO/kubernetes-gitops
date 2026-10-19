#!/usr/bin/env bash
# A single render is shared by schema, retention, HPA and security checks.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash "$repo_root/scripts/ci/render-all.sh" "$work/rendered"
python3 "$repo_root/scripts/ci/check-source-coverage.py" "$work/rendered" \
  "$repo_root/scripts/ci/known-gaps/external-applications.json"
bash "$repo_root/scripts/ci/check-litellm.sh" "$work/rendered/apps_overlays_main_litellm.yaml"
bash "$repo_root/scripts/ci/check-schemas.sh" "$work/rendered"
bash "$repo_root/scripts/ci/check-hpa.sh" "$work/rendered"
bash "$repo_root/scripts/ci/check-monitoring.sh" "$work/rendered/infrastructure_base_monitoring.yaml"
python3 "$repo_root/scripts/ci/check-pvc.py" "$work/rendered" \
  "$repo_root/scripts/ci/known-gaps/unprotected-pvcs.txt"
bash "$repo_root/scripts/ci/check-security.sh" "$work/rendered"
