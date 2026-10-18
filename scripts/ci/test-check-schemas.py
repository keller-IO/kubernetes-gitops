#!/usr/bin/env python3
"""Small, offline regression contract for CRD conversion + real kubeconform."""

import importlib.util
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import yaml


module = importlib.util.spec_from_file_location("schemas", Path(__file__).with_name("prepare-schemas.py"))
schemas = importlib.util.module_from_spec(module)
module.loader.exec_module(schemas)


class SchemaContract(unittest.TestCase):
    def test_exact_api_group_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "object.yaml").write_text("apiVersion: apps.typo/v1\nkind: Deployment\n")
            with patch.object(schemas, "supplementary", return_value=(None, [], {("apps/v1", "Deployment")})):
                with self.assertRaisesRegex(ValueError, "no schema for API kinds"):
                    schemas.prepare(root, root / "schemas", Path("config.json"))

    def test_download_requires_matching_pin(self):
        content = b"upstream schema bytes"
        checksum = hashlib.sha256(content).hexdigest()
        with patch.object(schemas.urllib.request, "urlopen", return_value=io.BytesIO(content)):
            self.assertEqual(schemas.download("https://example.test/schema", checksum), content)
        with patch.object(schemas.urllib.request, "urlopen", return_value=io.BytesIO(content)):
            with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
                schemas.download("https://example.test/schema", "0" * 64)
        with self.assertRaisesRegex(ValueError, "pinned SHA256"):
            schemas.download("https://example.test/schema", "latest")

    def test_strict_crd_with_kubernetes_extensions(self):
        schema = {
            "type": "object",
            "properties": {
                "spec": {
                    "type": "object",
                    "required": ["instances"],
                    "anyOf": [
                        {"properties": {"instances": {"minimum": 1}}, "required": ["instances"]},
                        {"required": ["port"]},
                    ],
                    "properties": {
                        "instances": {"type": "integer", "minimum": 1},
                        "port": {"x-kubernetes-int-or-string": True},
                        "options": {"type": "object", "x-kubernetes-preserve-unknown-fields": True},
                        "labels": {"type": "object", "additionalProperties": {"type": "string"}},
                        "note": {"type": "string", "nullable": True},
                        "template": {"type": "object", "x-kubernetes-embedded-resource": True},
                    },
                }
            },
        }
        crd = {
            "apiVersion": "apiextensions.k8s.io/v1",
            "kind": "CustomResourceDefinition",
            "metadata": {"name": "clusters.example.test"},
            "spec": {
                "group": "example.test",
                "names": {"kind": "Cluster", "plural": "clusters"},
                "scope": "Namespaced",
                "versions": [{"name": "v1", "served": True, "schema": {"openAPIV3Schema": schema}}],
            },
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rendered = root / "rendered"
            rendered.mkdir()
            (rendered / "operator.yaml").write_text(yaml.safe_dump(crd))
            destination = root / "schemas"
            schemas.prepare(rendered, destination)
            resource = {
                "apiVersion": "example.test/v1", "kind": "Cluster",
                "metadata": {"name": "test", "labels": {"app": "test"}},
                "spec": {
                    "instances": 1, "port": "http", "options": {"anything": [1, 2]},
                    "labels": {"app": "test"}, "note": None,
                    "template": {"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "test"}},
                },
            }

            def validate(value):
                manifest = root / "resource.yaml"
                manifest.write_text(yaml.safe_dump(value))
                result = subprocess.run([
                    "kubeconform", "-strict", "-schema-location",
                    str(destination / "{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json"),
                    str(manifest),
                ], capture_output=True, text=True)
                return result.returncode, result.stdout + result.stderr

            self.assertEqual(validate(resource), (0, ""))
            for bad_spec in ({"instances": "invalid"}, {"instances": 1, "typo": 1}, {}, {"instances": 1, "port": []}):
                with self.subTest(spec=bad_spec):
                    resource["spec"] = bad_spec
                    code, output = validate(resource)
                    self.assertNotEqual(code, 0, output)
                    self.assertIn("is invalid", output)
            resource["kind"] = "UnknownKind"
            code, output = validate(resource)
            self.assertNotEqual(code, 0, output)
            self.assertIn("could not find schema", output)

            crd["spec"]["versions"][0]["schema"] = {}
            (rendered / "operator.yaml").write_text(yaml.safe_dump(crd))
            with self.assertRaisesRegex(ValueError, "no validation schema"):
                schemas.prepare(rendered, destination)

    def test_legacy_schema_and_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            crd = {
                "kind": "CustomResourceDefinition", "spec": {
                    "group": "example.test", "names": {"kind": "Legacy"}, "version": "v1",
                    "validation": {"openAPIV3Schema": {"type": "object", "properties": {"spec": {"type": "string"}}}},
                },
            }
            (root / "crd.yaml").write_text(yaml.safe_dump(crd))
            schemas.prepare(root, root / "schemas")
            output = json.loads((root / "schemas/example.test/legacy_v1.json").read_text())
            self.assertFalse(output["additionalProperties"])
            crd["spec"]["validation"]["openAPIV3Schema"]["properties"]["spec"] = {"type": "integer"}
            (root / "conflict.yaml").write_text(yaml.safe_dump(crd))
            with self.assertRaisesRegex(ValueError, "conflicting rendered CRD"):
                schemas.prepare(root, root / "schemas")


if __name__ == "__main__":
    unittest.main()
