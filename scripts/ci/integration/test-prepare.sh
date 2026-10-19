#!/usr/bin/env bash
# Real SOPS encryption + KSOPS execution + Helm inflation; no cluster needed.
set -euo pipefail
ROOT="$(git rev-parse --show-toplevel)"
HERE="$ROOT/scripts/ci/integration"
TASK_TMP="$(mktemp -d)"
trap 'rm -rf "$TASK_TMP"' EXIT
export SOPS_AGE_KEY_FILE="$TASK_TMP/age-key.txt"
unset SOPS_AGE_KEY SOPS_AGE_KEY_CMD
age-keygen -o "$SOPS_AGE_KEY_FILE" 2>"$TASK_TMP/age.log"
recipient="$(age-keygen -y "$SOPS_AGE_KEY_FILE")"
python3 "$HERE/prepare.py" prepare "$ROOT" "$TASK_TMP/generated" "$(git rev-parse HEAD)" --recipient "$recipient"
for app in gatus goloom; do
  kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$TASK_TMP/generated/$app" >"$TASK_TMP/$app.yaml"
done
python3 "$HERE/prepare.py" appset "$TASK_TMP/generated" "$TASK_TMP/appset.yaml" 1111111111111111111111111111111111111111
python3 - "$TASK_TMP" <<'PY'
import json
from pathlib import Path
import sys
import yaml
root = Path(sys.argv[1])
gatus = list(yaml.safe_load_all((root/'gatus.yaml').read_text()))
goloom = list(yaml.safe_load_all((root/'goloom.yaml').read_text()))
assert any(x['kind'] == 'Deployment' for x in gatus)
assert any(x['kind'] == 'Secret' and x['metadata']['name'] == 'gatus-oidc' for x in gatus)
assert any(x['kind'] == 'Secret' and x['metadata']['name'] == 'gatus-db' for x in gatus)
assert not any(x['kind'] in ('Ingress', 'CronJob', 'ScheduledBackup') for x in gatus + goloom)
cluster = next(x for x in goloom if x['kind'] == 'Cluster')
assert cluster['spec']['storage']['storageClass'] == 'standard'
assert 'backup' not in cluster['spec']
assert cluster['spec']['instances'] == 1 and 'affinity' not in cluster['spec']
pvc = next(x for x in goloom if x['kind'] == 'PersistentVolumeClaim')
assert 'Prune=false' in pvc['metadata']['annotations']['argocd.argoproj.io/sync-options']
assert any(x['kind'] == 'Secret' and x['metadata']['name'] == 'goloom-db-app' for x in goloom)
for path in (root/'generated').rglob('*.sops.yaml'):
    encrypted = yaml.safe_load(path.read_text())
    assert encrypted['sops']['age']
    assert all(value.startswith('ENC[') for value in encrypted['stringData'].values())
spec = yaml.safe_load((root/'appset.yaml').read_text())['spec']
assert spec['template']['spec']['project'] == 'apps'
projects = list(yaml.safe_load_all((root/'generated/app-projects.yaml').read_text()))
assert any(x['kind'] == 'AppProject' and x['metadata']['name'] == 'apps' for x in projects)
generator = spec['generators'][0]['git']
assert {x['path'] for x in generator['directories']} == {'gatus', 'goloom'}
assert generator['revision'] == '1'*40
assert 'eq .path.basename "goloom"' in spec['templatePatch']
sources = spec['template']['spec']['sources']
assert len(sources) == 2 and sources[1]['ref'] == 'values'
assert len(sources[0]['targetRevision']) == 40
assert sources[1]['targetRevision'] == '1'*40
for app in ('gatus','goloom'):
    values = root/'generated'/('gatus/values.yaml' if app == 'gatus' else 'apps/base/goloom/values.yaml')
    text = values.read_text()
    assert 'auth.savar.de' not in text and 'jit.services' not in text and 'binaergewitter.de' not in text
print('Real SOPS/KSOPS/Helm pilot render and immutable multi-source assertions passed')
PY
# Deliberately reject production state changing back to SQLite: no fake fallback.
python3 - "$ROOT" "$TASK_TMP/negative" <<'PY'
from pathlib import Path
import shutil, sys, yaml
root, out = map(Path, sys.argv[1:])
for component in ('infrastructure/base/argocd','infrastructure/base/cnpg','apps/base/gatus','apps/base/goloom'):
    (out/component).mkdir(parents=True)
    for name in ('kustomization.yaml','values.yaml'):
        shutil.copy(root/component/name, out/component/name)
values = out/'apps/base/goloom/values.yaml'
data = yaml.safe_load(values.read_text()); data['database']['type'] = 'sqlite'
values.write_text(yaml.safe_dump(data))
PY
if python3 "$HERE/prepare.py" prepare "$TASK_TMP/negative" "$TASK_TMP/rejected" deadbeef --recipient "$recipient" >"$TASK_TMP/negative.log" 2>&1; then
  echo 'SQLite substitution was incorrectly accepted' >&2; exit 1
fi
rg -q 'refusing SQLite substitution' "$TASK_TMP/negative.log"
echo 'SQLite substitution negative passed'
