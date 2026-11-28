import importlib.util
from pathlib import Path
import unittest


class ScanGateTests(unittest.TestCase):
    def gate(self, report):
        path = Path(__file__).with_name("check_scan.py")
        self.assertTrue(path.exists(), "GoPhish scan gate is missing")
        spec = importlib.util.spec_from_file_location("gophish_scan_gate", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.check_report(report)

    def test_rejects_missing_binary_detection(self):
        self.assertIn("Go binary was not detected", self.gate({"Results": []}))

    def test_accepts_detected_binary_without_vulnerabilities(self):
        self.assertEqual([], self.gate({"Results": [{"Type": "gobinary"}]}))

    def test_rejects_high_or_critical_in_any_component(self):
        for severity in ("HIGH", "CRITICAL"):
            with self.subTest(severity=severity):
                errors = self.gate({"Results": [
                    {"Type": "gobinary"},
                    {"Type": "debian", "Vulnerabilities": [
                        {"Severity": severity, "VulnerabilityID": "CVE-fixture"}
                    ]},
                ]})
                self.assertTrue(any(severity in error for error in errors))

    def test_retains_medium_for_review_without_blanket_exception(self):
        self.assertEqual([], self.gate({"Results": [{
            "Type": "gobinary", "Vulnerabilities": [
                {"Severity": "MEDIUM", "VulnerabilityID": "CVE-fixture"}
            ],
        }]}))

    def test_rejects_malformed_reports_and_missing_severity(self):
        for report in (None, {}, {"Results": None}, {"Results": [None]},
                       {"Results": [{"Type": "gobinary",
                                     "Vulnerabilities": [{}]}]}):
            with self.subTest(report=report):
                self.assertTrue(self.gate(report))

    def test_rejects_eol_os(self):
        self.assertTrue(self.gate({
            "Metadata": {"OS": {"EOSL": True}},
            "Results": [{"Type": "gobinary"}],
        }))


if __name__ == "__main__":
    unittest.main()
