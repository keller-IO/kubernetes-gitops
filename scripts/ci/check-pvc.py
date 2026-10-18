#!/usr/bin/env python3
"""Require explicit Argo retention on rendered application PVCs."""
from pathlib import Path
import sys

import yaml


def violations(doc):
    if not isinstance(doc, dict) or doc.get("kind") != "PersistentVolumeClaim":
        return []
    options = doc.get("metadata", {}).get("annotations", {}).get(
        "argocd.argoproj.io/sync-options", "")
    tokens = [option.strip() for option in options.split(",")]
    # Argo trims comma-separated entries, not whitespace around '='. Reject
    # duplicates too: Argo's first-match semantics must not hide a true value.
    return [f"{key}=false" for key in ("Prune", "Delete")
            if [token for token in tokens if token.startswith(key + "=")] != [f"{key}=false"]]


def check(directory, allowlist):
    allowed = {}
    for line in allowlist.read_text().splitlines():
        entry = line.partition("#")[0].strip()
        if entry:
            allowed[entry] = False
    failed = False
    for path in sorted(directory.glob("apps_*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            missing = violations(doc)
            if not missing:
                continue
            meta = doc.get("metadata", {})
            key = f"{path.stem}:{meta.get('namespace', '-')}/{meta['name']}"
            if key in allowed:
                allowed[key] = True
                print(f"KNOWN GAP PVC {key}: {', '.join(missing)}")
            else:
                print(f"ERROR PVC {key}: missing {', '.join(missing)}", file=sys.stderr)
                failed = True
    for key, seen in allowed.items():
        if not seen:
            print(f"ERROR stale PVC exception: {key}", file=sys.stderr)
            failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(check(Path(sys.argv[1]), Path(sys.argv[2])))
