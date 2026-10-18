#!/usr/bin/env python3
"""GitHub needs results must be present and successful; skipped is not success."""
import json
import sys


def check(needs):
    expected = {"validate", "integration"}
    if set(needs) != expected:
        print(f"ERROR expected jobs {sorted(expected)}, got {sorted(needs)}", file=sys.stderr)
        return 1
    for name, job in needs.items():
        if job.get("result") != "success":
            print(f"ERROR required job {name}: {job.get('result', 'missing')}", file=sys.stderr)
            return 1
    print("All required CI jobs passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(check(json.loads(sys.argv[1])))
