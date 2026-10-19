#!/usr/bin/env python3
"""Build an isolated pilot from a Git snapshot; never read production SOPS files."""
import argparse
import copy
import json
from pathlib import Path
import subprocess

import yaml


def load(path):
    return yaml.safe_load(path.read_text())


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(yaml.safe_dump(value, sort_keys=False))


def chart(root, component):
    return load(root / component / "kustomization.yaml")["helmCharts"][0]


def encrypted(path, secret, recipient):
    # Feed plaintext over stdin: neither the generated Git repo nor artifacts hold it.
    result = subprocess.run(
        ["sops", "--config", "/dev/null", "--encrypt", "--input-type", "yaml", "--output-type", "yaml",
         "--age", recipient, "--encrypted-regex", "^(data|stringData)$", "/dev/stdin"],
        input=yaml.safe_dump(secret), text=True, check=True, capture_output=True,
    )
    path.write_text(result.stdout)


def secret(name, namespace, data):
    return {"apiVersion": "v1", "kind": "Secret", "metadata": {
        "name": name, "namespace": namespace}, "type": "Opaque", "stringData": data}


def prepare(root, output, revision, recipient):
    output.mkdir(parents=True, exist_ok=True)
    provenance = {"sourceRevision": revision, "overrides": [
        "ingress/OIDC/external checks disabled", "Kind standard storage, 1Gi volumes",
        "backup/monitoring disabled", "synthetic KSOPS secrets", "CI bootstrap identity"]}
    # Preserve production resources, image, chart version and KSOPS installation.
    argo = load(root / "infrastructure/base/argocd/values.yaml")
    argo["global"]["domain"] = "argocd.ci.invalid"
    argo["configs"]["cm"].pop("oidc.config", None)
    argo["configs"]["cm"]["url"] = "http://argocd-server.argocd.svc"
    argo["configs"]["cm"]["timeout.reconciliation"] = "15s"
    argo["configs"]["cm"]["resource.customizations.health.postgresql.cnpg.io_Cluster"] = """
hs = {status = "Progressing", message = "Waiting for database"}
if obj.status ~= nil and obj.status.phase == "Cluster in healthy state" then
  hs.status = "Healthy"
end
return hs
"""
    write(output / "argocd-values.yaml", argo)
    cnpg = load(root / "infrastructure/base/cnpg/values.yaml")
    cnpg["monitoring"] = {"podMonitorEnabled": False, "grafanaDashboard": {"create": False}}
    write(output / "cnpg-values.yaml", cnpg)
    provenance["argocdChart"] = chart(root, "infrastructure/base/argocd")
    provenance["cnpgChart"] = chart(root, "infrastructure/base/cnpg")

    gatus = load(root / "apps/base/gatus/values.yaml")
    gatus["ingress"] = {"enabled": False}
    gatus["config"] = {"ui": {"title": "CI pilot"}, "endpoints": [{
        "name": "goloom", "url": "http://goloom.goloom.svc:8080/healthz",
        "interval": "10s", "conditions": ["[STATUS] == 200"]}]}
    write(output / "gatus/values.yaml", gatus)
    gatus_chart = copy.deepcopy(chart(root, "apps/base/gatus"))
    write(output / "gatus/kustomization.yaml", {
        "apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
        "namespace": "gatus", "helmCharts": [gatus_chart], "generators": ["secret-generator.yaml"]})
    gatus_secret = secret("gatus-oidc", "gatus", {"OIDC_CLIENT_SECRET": "ci-only", "WATCHDOG_TOKEN": "ci-only"})
    encrypted(output / "gatus/secret.sops.yaml", gatus_secret, recipient)
    # Production envFrom references gatus-db (Postgres in monitoring-pg). The pilot
    # config above has no storage block, so Gatus stays in-memory and only needs
    # the Secret to exist.
    encrypted(output / "gatus/db-secret.sops.yaml",
              secret("gatus-db", "gatus", {"GATUS_DB_PASSWORD": "ci-only"}), recipient)

    goloom = load(root / "apps/base/goloom/values.yaml")
    if goloom["database"]["type"] != "postgres":
        raise ValueError("Pilot requires the production PostgreSQL contract; refusing SQLite substitution")
    goloom["oidc"] = {"enabled": False}
    goloom["ingress"] = {"enabled": False}
    goloom["config"]["publicBaseUrl"] = "http://goloom.goloom.svc:8080"
    goloom["bootstrap"] = {"adminEmail": "ci@example.invalid", "adminName": "CI pilot"}
    goloom["persistence"].update(storageClass="standard", size="1Gi")
    goloom.setdefault("podAnnotations", {})["ci.keller.io/source-revision"] = revision
    write(output / "apps/base/goloom/values.yaml", goloom)
    local = output / "goloom"
    local.mkdir(exist_ok=True)
    db = next(doc for doc in yaml.safe_load_all((root / "apps/base/goloom/database.yaml").read_text())
              if doc and doc["kind"] == "Cluster")
    db["spec"].pop("backup", None)
    db["spec"].pop("monitoring", None)
    # kind CI has a single node: required anti-affinity with 2 instances never schedules.
    db["spec"]["instances"] = 1
    db["spec"].pop("affinity", None)
    db["spec"]["storage"] = {"size": "1Gi", "storageClass": "standard"}
    write(local / "database.yaml", db)
    pvc = load(root / "apps/base/goloom/pvc.yaml")
    pvc["spec"]["storageClassName"] = "standard"
    pvc["spec"]["resources"]["requests"]["storage"] = "1Gi"
    write(local / "pvc.yaml", pvc)
    for name in ("namespace.yaml", "service-account.yaml"):
        write(local / name, load(root / f"apps/base/goloom/{name}"))
    write(local / "kustomization.yaml", {
        "apiVersion": "kustomize.config.k8s.io/v1beta1", "kind": "Kustomization",
        "namespace": "goloom", "resources": ["namespace.yaml", "service-account.yaml", "database.yaml", "pvc.yaml"],
        "generators": ["secret-generator.yaml"]})
    for directory, files in ((output / "gatus", ["secret.sops.yaml", "db-secret.sops.yaml"]),
                             (local, ["secret.sops.yaml", "db-app.sops.yaml"])):
        write(directory / "secret-generator.yaml", {"apiVersion": "viaduct.ai/v1", "kind": "ksops",
              "metadata": {"name": "ci-secrets", "annotations": {
                  "config.kubernetes.io/function": "exec:\n  path: ksops\n"}}, "files": files})
    encrypted(local / "secret.sops.yaml", secret("goloom-secrets", "goloom", {
        "DATABASE_URL": "postgres://goloom:ci-only-password@goloom-pg-rw:5432/goloom?sslmode=disable",
        "ENCRYPTION_KEY": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        "BOOTSTRAP_ADMIN_TOKEN": "ci-only-bootstrap-token"}), recipient)
    db_secret = secret("goloom-db-app", "goloom", {"username": "goloom", "password": "ci-only-password"})
    db_secret["type"] = "kubernetes.io/basic-auth"
    encrypted(local / "db-app.sops.yaml", db_secret, recipient)
    appset = load(root / "clusters/main/appset-apps.yaml")
    projects = list(yaml.safe_load_all((root / "clusters/main/projects.yaml").read_text()))
    (output / "app-projects.yaml").write_text(yaml.safe_dump_all(projects, sort_keys=False))
    source = copy.deepcopy(appset["spec"]["template"]["spec"]["sources"][0])
    # Resolve the chart tag to an immutable Git SHA before ArgoCD ever sees it.
    refs = subprocess.check_output(["git", "ls-remote", source["repoURL"],
                                   source["targetRevision"], source["targetRevision"] + "^{}"], text=True)
    lines = refs.splitlines()
    if not lines:
        raise ValueError("Cannot resolve Goloom chart revision")
    source["targetRevision"] = lines[-1].split()[0]
    provenance["goloomSource"] = source
    provenance["ignoreDifferences"] = appset["spec"]["template"]["spec"].get("ignoreDifferences", [])
    write(output / "application-set.yaml", appset)
    (output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")


def application_set(output, git_revision):
    provenance = json.loads((output / "provenance.json").read_text())
    url = "http://ci-git.argocd.svc.cluster.local:8080/pilot.git"
    # Exercise the candidate's actual template/templatePatch and Git directory
    # generator. Only the source, SHA and selected directories change.
    result = load(output / "application-set.yaml")
    result["metadata"] = {"name": "ci-pilot", "namespace": "argocd"}
    result["spec"]["generators"] = [{"git": {"repoURL": url, "revision": git_revision,
        "directories": [{"path": "gatus"}, {"path": "goloom"}]}}]
    template = result["spec"]["template"]["spec"]
    template["source"]["repoURL"] = url
    template["source"]["targetRevision"] = git_revision
    template["sources"] = [provenance["goloomSource"], {"repoURL": url,
        "targetRevision": git_revision, "ref": "values", "path": "goloom"}]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "appset"])
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("revision")
    parser.add_argument("--recipient")
    args = parser.parse_args()
    if args.action == "prepare":
        if not args.recipient:
            parser.error("--recipient is required for prepare")
        prepare(args.root, args.output, args.revision, args.recipient)
    else:
        write(args.output, application_set(args.root, args.revision))
