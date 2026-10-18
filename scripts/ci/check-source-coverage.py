#!/usr/bin/env python3
"""Freeze explicitly external Applications until their own rendering is integrated."""
import json
from pathlib import Path
import sys

import yaml

REPOSITORY = "https://github.com/keller-IO/kubernetes-gitops.git"


def check(directory, exceptions):
    reviewed = {entry["name"]: entry for entry in exceptions}
    if len(reviewed) != len(exceptions) or any(not x.get("reason") for x in exceptions):
        raise ValueError("External source exceptions require unique names and reasons")
    seen = set()
    failed = False
    for path in sorted(directory.glob("clusters_main_*.yaml")):
        for doc in yaml.safe_load_all(path.read_text()):
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            spec = doc["spec"]
            name = doc["metadata"]["name"]
            sources = spec.get("sources") or [spec.get("source", {})]
            if any(source.get("repoURL") != REPOSITORY for source in sources):
                if name not in reviewed or reviewed[name]["spec"] != spec:
                    print(f"ERROR {name}: unrendered external Application is new or changed; integrate source validation first", file=sys.stderr)
                    failed = True
                else:
                    seen.add(name)
                    print(f"KNOWN GAP {name}: frozen external spec; application manifests are outside this CI")
                continue
            for source in sources:
                relative = source.get("path", "")
                if relative == "clusters/main":
                    continue
                if not relative and source.get("ref"):
                    continue
                expected = directory / (relative.replace("/", "_") + ".yaml")
                if not relative or not expected.is_file():
                    print(f"ERROR {name}: source path {relative!r} was not rendered", file=sys.stderr)
                    failed = True
    for name in reviewed.keys() - seen:
        print(f"ERROR stale external Application exception: {name}", file=sys.stderr)
        failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(check(Path(sys.argv[1]), json.loads(Path(sys.argv[2]).read_text())))
