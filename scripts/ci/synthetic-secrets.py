#!/usr/bin/env python3
"""Copy GitOps sources and replace encrypted payloads before fresh SOPS encryption."""
import base64
from pathlib import Path
import re
import shutil
import subprocess
import sys

import yaml


def synthetic(value):
    if isinstance(value, dict):
        return {key: synthetic(item) for key, item in value.items()}
    if isinstance(value, list):
        return [synthetic(item) for item in value]
    if isinstance(value, str) and value.startswith("ENC["):
        if re.search(r"type:int\]$", value):
            return 1
        if re.search(r"type:bool\]$", value):
            return False
        return "ci-synthetic-value"
    return value


def prepare(source, destination, recipient):
    for directory in ("apps", "infrastructure", "clusters"):
        shutil.copytree(source / directory, destination / directory,
                        ignore=shutil.ignore_patterns("charts", ".agents", ".git"))
    (destination / "scripts").mkdir()
    shutil.copy2(source / "scripts/render.sh", destination / "scripts/render.sh")
    count = 0
    for path in sorted(destination.rglob("*.sops.yaml")):
        docs = list(yaml.safe_load_all(path.read_text()))
        plain = []
        patterns = set()
        for original in docs:
            if original is None:
                continue
            if not isinstance(original, dict):
                raise ValueError(f"Expected SOPS mapping: {path.relative_to(destination)}")
            doc = synthetic(original)
            metadata = doc.pop("sops", {})
            if doc.get("kind") == "Secret":
                # Replace even blueprint placeholders; preserve the exact key set.
                for key in doc.get("data", {}):
                    doc["data"][key] = base64.b64encode(b"ci-synthetic-value").decode()
                for key in doc.get("stringData", {}):
                    doc["stringData"][key] = "ci-synthetic-value"
            patterns.add(metadata.get("encrypted_regex", "^(data|stringData|spec)$"))
            plain.append(doc)
            count += 1
        # Encrypt the complete YAML stream in one operation: all documents must
        # share the data key, as expected by SOPS/KSOPS multi-document decoding.
        result = subprocess.run(
            ["sops", "--config", "/dev/null", "--encrypt", "--age", recipient,
             "--encrypted-regex", "|".join(sorted(patterns)), "--input-type", "yaml", "--output-type", "yaml", "/dev/stdin"],
            input=yaml.safe_dump_all(plain), text=True, capture_output=True, check=True)
        path.write_text(result.stdout)
    print(f"Prepared {count} synthetic SOPS documents; production keys were not used.")


if __name__ == "__main__":
    prepare(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3])
