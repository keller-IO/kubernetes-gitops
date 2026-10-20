#!/usr/bin/env python3
"""Convert rendered CRD OpenAPI schemas for strict kubeconform validation.

Use rendered CRDs plus the narrow, checksum-pinned upstream inputs in config.
Kubernetes CEL rules and webhook validation are not JSON Schema and remain
outside this local check.
"""

import copy
import hashlib
import json
from pathlib import Path
import re
import sys
import urllib.request

import yaml


def convert(schema):
    """Translate OpenAPI extensions without closing intentional free-form maps."""
    result = copy.deepcopy(schema)
    for key in ("properties", "definitions", "patternProperties"):
        if key in result:
            result[key] = {name: convert(value) for name, value in result[key].items()}
    for key in ("items", "additionalProperties", "not"):
        if isinstance(result.get(key), dict):
            result[key] = convert(result[key])
    for key in ("allOf", "anyOf", "oneOf"):
        if key in result:
            result[key] = [convert(value) for value in result[key]]

    if result.get("x-kubernetes-int-or-string") or result.get("format") == "int-or-string":
        result.pop("type", None)
        result.pop("format", None)
        result.setdefault("anyOf", [{"type": "integer"}, {"type": "string"}])
    if result.pop("nullable", False):
        if isinstance(result.get("type"), str):
            result["type"] = [result["type"], "null"]
        else:
            result = {"anyOf": [result, {"type": "null"}]}

    if result.get("x-kubernetes-preserve-unknown-fields"):
        result.setdefault("additionalProperties", True)
    # Composition branches can mention just a subset of properties. Closing
    # those would reject sibling fields defined by the parent structural schema.
    elif schema.get("type") == "object":
        result.setdefault("additionalProperties", False)

    if result.get("x-kubernetes-embedded-resource"):
        result.setdefault("properties", {}).update(
            apiVersion={"type": "string"}, kind={"type": "string"}, metadata={"type": "object"}
        )
    return result


def download(url, expected_hash):
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise ValueError(f"{url}: expected a pinned SHA256 checksum")
    with urllib.request.urlopen(url, timeout=60) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != expected_hash:
        raise ValueError(f"{url}: SHA256 mismatch; review upstream schema before updating its pin")
    return content


def supplementary(config_path):
    config = json.loads(config_path.read_text())
    version = config["kubernetesVersion"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("kubernetesVersion must be an exact x.y.z version")
    # The standard catalog omits recursive CRD schemas. Keep recursive references
    # from the official Kubernetes OpenAPI document instead of skipping CRDs.
    url = f"https://raw.githubusercontent.com/kubernetes/kubernetes/v{version}/api/openapi-spec/swagger.json"
    openapi = json.loads(download(url, config["kubernetesOpenAPIHash"]))
    definitions = openapi["definitions"]
    registry = {
        (f"{gvk['group']}/{gvk['version']}".lstrip("/"), gvk["kind"])
        for definition in definitions.values()
        for gvk in definition.get("x-kubernetes-group-version-kind", [])
    }
    # Kubernetes Time marshals an unset value as null (e.g. creationTimestamp).
    for name in ("Time", "MicroTime"):
        key = f"io.k8s.apimachinery.pkg.apis.meta.v1.{name}"
        if key in definitions:
            definitions[key]["nullable"] = True
    name = "io.k8s.apiextensions-apiserver.pkg.apis.apiextensions.v1.CustomResourceDefinition"
    schema = convert(definitions[name])
    required = set()

    def references(value):
        if isinstance(value, dict):
            reference = value.get("$ref", "")
            if isinstance(reference, str) and reference.startswith("#/definitions/"):
                target = reference.removeprefix("#/definitions/")
                if target not in required:
                    required.add(target)
                    references(definitions[target])
            for child in value.values():
                references(child)
        elif isinstance(value, list):
            for child in value:
                references(child)

    references(schema)
    schema["definitions"] = {name: convert(definitions[name]) for name in required}

    # Cilium installs its CRDs at operator runtime, so Helm renders none. Match
    # its checked-in chart version exactly and verify this narrow upstream input.
    repo = Path(__file__).resolve().parents[2]
    kustomization = yaml.safe_load((repo / "infrastructure/base/cilium/kustomization.yaml").read_text())
    cilium_version = next(chart["version"] for chart in kustomization["helmCharts"] if chart["name"] == "cilium")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", str(cilium_version)):
        raise ValueError("Cilium chart must use an exact x.y.z version")
    crds = []
    for kind, path in (
        ("networkPolicy", "v2/ciliumnetworkpolicies.yaml"),
        ("l2AnnouncementPolicy", "v2alpha1/ciliuml2announcementpolicies.yaml"),
        ("loadBalancerIPPool", "v2/ciliumloadbalancerippools.yaml"),
    ):
        url = f"https://raw.githubusercontent.com/cilium/cilium/v{cilium_version}/pkg/k8s/apis/cilium.io/client/crds/{path}"
        crds.append(yaml.safe_load(download(url, config["ciliumCRDHashes"][kind])))

    # The VM stack consumes these legacy Prometheus APIs but its current chart
    # no longer includes their CRDs. Schema input alone does not install them.
    prometheus = config["prometheusOperatorSchemas"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", prometheus["version"]):
        raise ValueError("Prometheus operator schemas require an exact x.y.z version")
    for kind in ("podmonitors", "servicemonitors"):
        url = f"https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v{prometheus['version']}/example/prometheus-operator-crd/monitoring.coreos.com_{kind}.yaml"
        crds.append(yaml.safe_load(download(url, prometheus["sha256"][kind])))

    # Talos creates serviceaccounts.talos.dev at runtime once
    # kubernetesTalosAPIAccess is enabled; no chart renders it. Its golden test
    # output is the generated CRD. Pinned separately from the Plan's Talos
    # version so routine Talos patch bumps do not require a new schema hash.
    talos = config["talosServiceAccountCRD"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", talos["version"]):
        raise ValueError("Talos ServiceAccount CRD schema requires an exact x.y.z version")
    url = f"https://raw.githubusercontent.com/siderolabs/talos/v{talos['version']}/internal/app/machined/pkg/controllers/k8s/internal/k8stemplates/testdata/talos-service-account-crd.yaml"
    crds.append(yaml.safe_load(download(url, talos["sha256"])))
    return schema, crds, registry


def prepare(rendered, destination, config_path=None):
    files = sorted(path for path in rendered.rglob("*") if path.suffix in (".yaml", ".yml"))
    if not rendered.is_dir() or not files:
        raise ValueError(f"{rendered}: expected a nonempty rendered YAML directory")
    schemas = {}
    resources = 0
    builtin = None
    registry = set()
    rendered_kinds = set()
    if config_path:
        builtin, upstream, registry = supplementary(config_path)
        documents = [("Supplementary upstream CRDs", upstream)]
    else:
        documents = []
    # Read the YAML once; the caller's render is also what kubeconform validates.
    for path in files:
        with path.open() as stream:
            documents.append((path, list(yaml.safe_load_all(stream))))
    for path, objects in documents:
        for document in objects:
            if document is None:
                continue
            if not isinstance(document, dict):
                raise ValueError(f"{path}: expected a Kubernetes object")
            if path != "Supplementary upstream CRDs":
                resources += 1
                rendered_kinds.add((document.get("apiVersion"), document.get("kind")))
            if document.get("kind") != "CustomResourceDefinition":
                continue
            spec = document["spec"]
            group, kind = spec["group"], spec["names"]["kind"]
            versions = spec.get("versions") or [{"name": spec["version"]}]
            for version in versions:
                if not version.get("served", True):
                    continue
                name = version["name"]
                if not all(re.fullmatch(r"[A-Za-z0-9_.-]+", part) for part in (group, kind, name)):
                    raise ValueError(f"{path}: unsafe CRD group/kind/version")
                original = version.get("schema", spec.get("validation", {})).get("openAPIV3Schema")
                if not original:
                    raise ValueError(f"{path}: {group}/{name}/{kind} has no validation schema")
                schema = convert(original)
                schema.setdefault("properties", {}).update(
                    apiVersion={"type": "string", "enum": [f"{group}/{name}"]},
                    kind={"type": "string", "enum": [kind]},
                    metadata={"type": "object"},
                )
                schema.setdefault("additionalProperties", False)
                key = f"{group}/{kind.lower()}_{name}.json"
                registry.add((f"{group}/{name}", kind))
                if key in schemas and schemas[key] != schema:
                    raise ValueError(f"{path}: conflicting rendered CRD schema for {group}/{name}/{kind}")
                schemas[key] = schema
    if not resources:
        raise ValueError(f"{rendered}: no Kubernetes resources found")
    if config_path and (missing := rendered_kinds - registry):
        raise ValueError(f"no schema for API kinds: {sorted(missing, key=str)}")
    if builtin:
        schemas["apiextensions.k8s.io/customresourcedefinition_v1.json"] = builtin
    for key, schema in schemas.items():
        output = destination / key
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(schema, sort_keys=True) + "\n")
    print(f"Prepared {len(schemas)} CRD version schemas from {resources} rendered resources.")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 4:
            raise ValueError("Usage: prepare-schemas.py RENDERED_DIRECTORY SCHEMA_DIRECTORY CONFIG_JSON")
        prepare(Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]))
    except (KeyError, TypeError, ValueError, OSError, yaml.YAMLError) as error:
        sys.exit(f"ERROR: {error}")
