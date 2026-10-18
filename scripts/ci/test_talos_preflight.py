"""Exercise upgrade stop conditions and continuous recovery without a cluster."""

import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "infrastructure/base/system-upgrade-controller/preflight.py"
spec = importlib.util.spec_from_file_location("preflight", SOURCE)
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


def healthy():
    return {
        "nodes": [{"metadata": {"name": "worker1", "labels": {}}, "spec": {},
                   "status": {"conditions": [{"type": "Ready", "status": "True"}],
                              "nodeInfo": {"osImage": "Talos (v1.13.4)"}}}],
        "server_version": {"major": "1", "minor": "35"},
        "clusters": [{"metadata": {"namespace": "app", "name": "db"},
                      "spec": {"instances": 3, "affinity": {"podAntiAffinityType": "required"}},
                      "status": {"readyInstances": 3, "currentPrimary": "db-1", "targetPrimary": "db-1",
                                 "conditions": [{"type": "Ready", "status": "True"}]}}],
        "workloads": [], "pods": [
            {"metadata": {"namespace": "app", "name": f"db-{n}", "labels": {"cnpg.io/cluster": "db"},
                          "ownerReferences": [{"kind": "Cluster", "controller": True}]},
             "spec": {"nodeName": f"worker{n}"},
             "status": {"phase": "Running", "conditions": [{"type": "Ready", "status": "True"}]}}
            for n in (1, 2, 3)], "webhooks": [],
        "system_labels": {"kubernetes.io/metadata.name": "kube-system"},
        "plan": {"status": {"latestHash": "abc", "latestVersion": "v1.13.5"}},
    }


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict("os.environ", {"DRAIN_KUBECTL_IMAGE": "rancher/kubectl:v1.35.0"})
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def check(self, state):
        return preflight.blockers(state, "v1.13.5", "worker1")

    def test_healthy_cluster_can_drain(self):
        self.assertEqual(self.check(healthy()), [])

    def test_drain_blockers(self):
        changes = [
            lambda s: s["nodes"][0]["spec"].update(unschedulable=True),
            lambda s: s["nodes"][0]["status"].update(conditions=[]),
            lambda s: s["clusters"][0]["spec"].update(instances=1),
            lambda s: s["clusters"][0]["spec"].update(instances=2),
            lambda s: s["clusters"][0]["spec"].update(enablePDB=False),
            lambda s: s["clusters"][0]["spec"].update(affinity={"podAntiAffinityType": "preferred"}),
            lambda s: s["clusters"][0]["spec"]["affinity"].update(enablePodAntiAffinity=False),
            lambda s: s["pods"][1]["spec"].update(nodeName="worker1"),
            lambda s: s["clusters"][0]["status"].update(readyInstances=2),
            lambda s: s["clusters"][0]["status"].update(targetPrimary="db-2"),
            lambda s: s["plan"]["status"].update(latestVersion="v1.13.6"),
            lambda s: s["nodes"][0]["status"]["nodeInfo"].update(osImage="Talos (v1.15.0)"),
            lambda s: s["nodes"][0]["status"]["nodeInfo"].update(osImage="Talos (v1.11.9)"),
            lambda s: s["nodes"].clear(),
            lambda s: s["server_version"].update(minor="33"),
            lambda s: s["clusters"][0]["status"]["conditions"].append({"type": "LastBackupSucceeded", "status": "False"}),
        ]
        for change in changes:
            state = healthy()
            change(state)
            with self.subTest(change=change):
                self.assertTrue(self.check(state))

    def test_job_success_does_not_prove_os_upgrade(self):
        state = healthy()
        node = state["nodes"][0]
        node["metadata"]["labels"]["plan.upgrade.cattle.io/talos"] = "abc"
        self.assertTrue(self.check(state))
        node["status"]["nodeInfo"]["osImage"] = "Talos (v1.13.5)"
        self.assertEqual(self.check(state), [])

    def test_control_plane_does_not_require_unrelated_database_ha(self):
        state = healthy()
        state["clusters"][0]["spec"] = {"instances": 1}
        state["clusters"][0]["status"]["readyInstances"] = 1
        state["pods"] = state["pods"][:1]
        state["nodes"].append({"metadata": {"name": "cp1"}, "spec": {},
                               "status": state["nodes"][0]["status"]})
        self.assertEqual(preflight.blockers(state, "v1.13.5", "cp1"), [])
        state["clusters"][0]["status"]["readyInstances"] = 0
        self.assertTrue(preflight.blockers(state, "v1.13.5", "cp1"))

    def test_emptydir_refuses_before_cordon_only_on_target_node(self):
        state = healthy()
        pod = {"metadata": {"namespace": "app", "name": "cache", "ownerReferences": [
            {"kind": "ReplicaSet", "controller": True}]},
               "spec": {"nodeName": "worker1", "volumes": [{"name": "queue", "emptyDir": {}}]},
               "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        state["pods"].append(pod)
        self.assertTrue(any("emptyDir blocks drain" in e for e in self.check(state)))
        pod["spec"]["nodeName"] = "worker2"
        self.assertEqual(self.check(state), [])
        pod["spec"]["nodeName"] = "worker1"
        pod["metadata"]["ownerReferences"] = [{"kind": "DaemonSet", "controller": True}]
        self.assertEqual(self.check(state), [])

    def test_unmanaged_pod_refuses_before_cordon(self):
        state = healthy()
        state["pods"][0]["metadata"]["ownerReferences"] = []
        self.assertTrue(any("unmanaged Pod" in e for e in self.check(state)))

    def test_suc_controller_and_job_use_native_drain_exemption(self):
        state = healthy()
        pod = {"metadata": {"namespace": "system-upgrade-controller", "name": "controller", "labels": {
            "upgrade.cattle.io/controller": "system-upgrade-controller"}, "ownerReferences": [
            {"kind": "ReplicaSet", "controller": True}]},
               "spec": {"nodeName": "worker1", "volumes": [{"name": "tmp", "emptyDir": {}}]},
               "status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        state["pods"].append(pod)
        self.assertEqual(self.check(state), [])
        pod["metadata"]["ownerReferences"] = [{"kind": "Job", "controller": True}]
        pod["status"]["conditions"] = []
        self.assertEqual(self.check(state), [])
        pod["metadata"]["labels"] = {}
        self.assertTrue(any("emptyDir blocks drain" in e for e in self.check(state)))

    def test_running_but_unready_pod_blocks(self):
        state = healthy()
        state["pods"].append({"metadata": {"namespace": "app", "name": "app"},
                              "status": {"phase": "Running", "conditions": []}})
        self.assertTrue(self.check(state))
        state["pods"][-1]["metadata"]["ownerReferences"] = [{"kind": "Job"}]
        self.assertEqual(self.check(state), [])

    def test_missing_workload_pods_do_not_look_healthy(self):
        state = healthy()
        state["workloads"] = [{"kind": "Deployment", "metadata": {"namespace": "app", "name": "app", "generation": 2},
                               "spec": {"replicas": 1}, "status": {"observedGeneration": 2}}]
        self.assertTrue(self.check(state))
        state["workloads"][0]["status"]["readyReplicas"] = 1
        self.assertEqual(self.check(state), [])

    def test_fail_closed_webhook_cannot_gate_cni(self):
        state = healthy()
        hook = {"name": "injector", "failurePolicy": "Fail", "rules": [{
            "apiGroups": [""], "resources": ["pods"], "operations": ["CREATE"]}]}
        state["webhooks"] = [{"webhooks": [hook]}]
        self.assertTrue(self.check(state))
        hook["namespaceSelector"] = {"matchExpressions": [{"key": "netbird.io/webhook", "operator": "In", "values": ["enabled"]}]}
        self.assertEqual(self.check(state), [])
        state["system_labels"]["netbird.io/webhook"] = "enabled"
        self.assertTrue(self.check(state))
        hook["namespaceSelector"] = {"matchExpressions": [{"key": "kubernetes.io/metadata.name", "operator": "NotIn", "values": ["kube-system"]}]}
        self.assertEqual(self.check(state), [])

    def test_transient_health_and_api_failure_reset_stability(self):
        ticks, calls = [0], []

        def snapshot(namespace):
            calls.append(ticks[0])
            if ticks[0] == 15:
                raise OSError("no API")
            return healthy()

        def sleep(seconds):
            ticks[0] += seconds

        preflight.wait_until_safe(snapshot, "v1.13.5", "system-upgrade-controller", "worker1",
                                  clock=lambda: ticks[0], sleep=sleep, timeout=120, stable=60)
        self.assertEqual(ticks[0], 90)
        self.assertEqual(len(calls), 7)

    def test_forbidden_api_fails_closed_before_cordon(self):
        ticks = [0]

        def forbidden(namespace):
            raise PermissionError("forbidden")

        def sleep(seconds):
            ticks[0] += seconds

        with self.assertRaisesRegex(RuntimeError, "not cordoned"):
            preflight.wait_until_safe(forbidden, "v1.13.5", "system-upgrade-controller", "worker1",
                                      clock=lambda: ticks[0], sleep=sleep, timeout=30)

    def test_missing_talosconfig_refuses_before_api(self):
        with patch.dict("os.environ", {"SYSTEM_UPGRADE_PLAN_LATEST_VERSION": "v1.13.5"}):
            with patch.object(preflight.Path, "is_file", return_value=False):
                with self.assertRaisesRegex(RuntimeError, "credential missing"):
                    preflight.main()

    def test_transport_uses_tls_bearer_get_and_fresh_token(self):
        api = preflight.API.__new__(preflight.API)
        api.context, api.directory = object(), Path("/fake/sa")
        with patch.object(preflight.Path, "read_text", side_effect=["first\n", "rotated\n"]):
            with patch.object(preflight, "urlopen") as transport:
                transport.return_value.__enter__.return_value.read.return_value = b'{"items": []}'
                self.assertEqual(api.items("/api/v1/nodes"), [])
                self.assertEqual(api.items("/api/v1/pods"), [])
                first, second = transport.call_args_list
                self.assertEqual(first.args[0].get_method(), "GET")
                self.assertEqual(first.args[0].full_url, "https://kubernetes.default.svc/api/v1/nodes")
                self.assertEqual(first.args[0].get_header("Authorization"), "Bearer first")
                self.assertEqual(second.args[0].get_header("Authorization"), "Bearer rotated")
                self.assertIs(first.kwargs["context"], api.context)


if __name__ == "__main__":
    unittest.main()
