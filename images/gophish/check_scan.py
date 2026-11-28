"""Fail closed if Trivy missed the binary or found high/critical components."""

import json
from pathlib import Path
import sys


def check_report(report):
    if not isinstance(report, dict) or not isinstance(report.get("Results"), list):
        return ["Invalid Trivy report"]
    results = report["Results"]
    if any(not isinstance(result, dict) for result in results):
        return ["Invalid Trivy result"]
    errors = []
    if not any(result.get("Type") == "gobinary" for result in results):
        errors.append("Go binary was not detected")
    metadata = report.get("Metadata", {})
    if not isinstance(metadata, dict):
        return ["Invalid Trivy metadata"]
    operating_system = metadata.get("OS", {})
    if not isinstance(operating_system, dict):
        return ["Invalid Trivy OS metadata"]
    if operating_system.get("EOSL"):
        errors.append("End-of-life runtime OS")
    for result in results:
        vulnerabilities = result.get("Vulnerabilities") or []
        if not isinstance(vulnerabilities, list):
            errors.append("Invalid vulnerability list")
            continue
        for vulnerability in vulnerabilities:
            if not isinstance(vulnerability, dict) or vulnerability.get("Severity") not in {
                "UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL",
            }:
                errors.append("Invalid vulnerability severity")
                continue
            severity = vulnerability["Severity"]
            if severity in {"HIGH", "CRITICAL"}:
                errors.append(f"{severity}: {vulnerability.get('VulnerabilityID', 'unspecified')}")
    return errors


def main():
    try:
        report = json.loads(Path(sys.argv[1]).read_text())
    except (IndexError, OSError, ValueError) as error:
        print(f"Cannot read Trivy report: {error}", file=sys.stderr)
        return 1
    errors = check_report(report)
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("Go binary detected; no HIGH/CRITICAL component findings. Review all other findings.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
