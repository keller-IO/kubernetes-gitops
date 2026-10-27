import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import yaml

import check_export

HERE = Path(__file__).resolve().parent


def write_export(directory, docs, files=()):
    manifest = [{"model": "documents.tag", "pk": 1, "fields": {"name": "Steuer"}}]
    for pk, name in docs:
        manifest.append(
            {"model": "documents.document", "pk": pk, "fields": {}, check_export.EXPORTED_FILE_NAME: name}
        )
    (directory / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    for name in files:
        (directory / name).write_bytes(b"%PDF-1.7")


def run_main(directory):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return check_export.main(["check_export.py", str(directory)])


class CheckExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_complete_export_passes(self):
        write_export(self.dir, [(1, "0000001.pdf"), (2, "0000002.pdf")], ["0000001.pdf", "0000002.pdf"])
        self.assertEqual(check_export.check(self.dir), (2, []))
        self.assertEqual(run_main(self.dir), 0)

    def test_valid_manifest_without_documents_fails(self):
        write_export(self.dir, [])
        self.assertEqual(check_export.check(self.dir), (0, []))
        self.assertEqual(run_main(self.dir), 1)

    def test_empty_list_manifest_fails(self):
        (self.dir / "manifest.json").write_text("[]", encoding="utf-8")
        self.assertEqual(run_main(self.dir), 1)

    def test_missing_original_fails(self):
        write_export(self.dir, [(1, "0000001.pdf"), (2, "0000002.pdf")], ["0000001.pdf"])
        self.assertEqual(check_export.check(self.dir), (2, ["0000002.pdf"]))
        self.assertEqual(run_main(self.dir), 1)

    def test_missing_or_broken_manifest_fails(self):
        self.assertEqual(run_main(self.dir), 1)
        (self.dir / "manifest.json").write_text('{"model": ', encoding="utf-8")
        self.assertEqual(run_main(self.dir), 1)
        (self.dir / "manifest.json").write_text("{}", encoding="utf-8")
        self.assertEqual(run_main(self.dir), 1)


class CronJobWiringTests(unittest.TestCase):
    """Die Pruefung muss im Init-Container vor rclone laufen: scheitert sie,
    startet der Sync-Container nicht und export/current bleibt unveraendert."""

    def setUp(self):
        self.cronjob = yaml.safe_load((HERE / "offsite-backup.yaml").read_text(encoding="utf-8"))
        self.pod = self.cronjob["spec"]["jobTemplate"]["spec"]["template"]["spec"]

    def test_check_runs_in_init_container_after_exporter(self):
        (exporter,) = self.pod["initContainers"]
        script = exporter["args"][0]
        self.assertIn("set -eu", script)
        self.assertLess(script.index("document_exporter"), script.index("check_export.py"))
        self.assertNotIn("exec ", script)

    def test_sync_only_in_regular_container(self):
        for container in self.pod["initContainers"]:
            self.assertNotIn("rclone sync", " ".join(container.get("command", []) + container.get("args", [])))
        (rclone,) = self.pod["containers"]
        self.assertIn("rclone sync", rclone["args"][0])

    def test_check_script_is_mounted(self):
        kustomization = yaml.safe_load((HERE / "kustomization.yaml").read_text(encoding="utf-8"))
        generated = {g["name"]: g["files"] for g in kustomization["configMapGenerator"]}
        self.assertIn("check_export.py", generated["paperless-offsite-backup-code"])
        volumes = {v["name"]: v for v in self.pod["volumes"]}
        self.assertEqual(volumes["code"]["configMap"]["name"], "paperless-offsite-backup-code")

    def test_job_carries_backup_labels(self):
        # Das Runbook sucht aktive Laeufe mit get jobs -l ...component=backup.
        labels = self.cronjob["spec"]["jobTemplate"]["metadata"]["labels"]
        self.assertEqual(labels.get("app.kubernetes.io/component"), "backup")
        self.assertNotIn("app.kubernetes.io/instance", labels)

    def test_emptydir_mounts_have_no_subpath(self):
        # subPath-Verzeichnisse legt kubelet als root an; die Container laufen als 1000.
        emptydirs = {v["name"] for v in self.pod["volumes"] if "emptyDir" in v}
        self.assertTrue(emptydirs)
        for container in self.pod["initContainers"] + self.pod["containers"]:
            for mount in container["volumeMounts"]:
                if mount["name"] in emptydirs:
                    self.assertNotIn("subPath", mount, f"{container['name']}: {mount['mountPath']}")


if __name__ == "__main__":
    unittest.main()
