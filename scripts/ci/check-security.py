#!/usr/bin/env python3
"""Fail Trivy findings outside an exact, counted, expiring legacy baseline."""
from collections import Counter
from datetime import date
import json
from pathlib import Path
import sys


def findings(report):
    results = report.get("Results")
    if not isinstance(results, list) or not results:
        raise ValueError("Trivy report has no scan results")
    found = Counter()
    for result in results:
        for item in result.get("Misconfigurations", []):
            if item.get("Status") == "FAIL" and item["Severity"] in ("HIGH", "CRITICAL"):
                found[(Path(result["Target"]).name, item["ID"], item["Message"])] += 1
    return found


def check(report, baseline, today=None):
    today = today or date.today()
    remaining = findings(report)
    failed = False
    seen = set()
    for exception in baseline:
        key = (exception["target"], exception["id"], exception["message"])
        if key in seen or not exception.get("reason") or exception["count"] < 1:
            raise ValueError(f"Malformed/duplicate security exception: {key[:2]}")
        seen.add(key)
        if date.fromisoformat(exception["expires"]) <= today:
            print(f"ERROR expired security exception: {key[0]} {key[1]}", file=sys.stderr)
            failed = True
        actual = remaining.pop(key, 0)
        if actual != exception["count"]:
            print(f"ERROR {key[0]} {key[1]}: expected {exception['count']} existing findings, got {actual}; "
                  "remove resolved exceptions or fix new findings", file=sys.stderr)
            failed = True
    for (target, identifier, message), count in sorted(remaining.items()):
        print(f"ERROR {target} {identifier} ({count}): {message}", file=sys.stderr)
        failed = True
    print(f"Security baseline: {sum(findings(report).values())} findings, {len(baseline)} exact exceptions.")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(check(json.loads(Path(sys.argv[1]).read_text()),
                          json.loads(Path(sys.argv[2]).read_text())))
