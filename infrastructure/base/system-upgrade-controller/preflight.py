"""Read-only, fail-closed SUC prepare check; Kubernetes API via stdlib only."""

import json
import os
from pathlib import Path
import re
import ssl
import time
from urllib.request import Request, urlopen


def ready(obj):
    return any(c.get("type") == "Ready" and c.get("status") == "True"
               for c in obj.get("status", {}).get("conditions", []))


def selector_matches(selector, labels):
    if any(labels.get(k) != v for k, v in selector.get("matchLabels", {}).items()):
        return False
    for e in selector.get("matchExpressions", []):
        key, op, values = e["key"], e["operator"], e.get("values", [])
        if op not in ("In", "NotIn", "Exists", "DoesNotExist"):
            raise ValueError("unsupported namespace selector operator")
        if ((op == "In" and labels.get(key) not in values)
                or (op == "NotIn" and labels.get(key) in values)
                or (op == "Exists" and key not in labels)
                or (op == "DoesNotExist" and key in labels)):
            return False
    return True


def blockers(state, target, namespace):
    errors = []
    plan_hash = state["plan"].get("status", {}).get("latestHash")
    if not plan_hash or state["plan"].get("status", {}).get("latestVersion") != target:
        errors.append("Talos Plan has not resolved the requested version")
    if not state["nodes"]:
        errors.append("no nodes returned")
    client = re.search(r":v(\d+)\.(\d+)\.\d+(?:@|$)", os.environ.get("DRAIN_KUBECTL_IMAGE", ""))
    server = state["server_version"]
    server_minor = re.match(r"\d+", server["minor"])
    if (not client or not server_minor or client[1] != server["major"]
            or abs(int(client[2]) - int(server_minor[0])) > 1):
        errors.append("drain kubectl is outside supported API version skew")
    for node in state["nodes"]:
        name = node["metadata"]["name"]
        if not ready(node) or node.get("spec", {}).get("unschedulable", False):
            errors.append(f"node {name} is not Ready and schedulable")
        image = node.get("status", {}).get("nodeInfo", {}).get("osImage", "")
        version = re.fullmatch(r"Talos \((v\d+\.\d+\.\d+)\)", image)
        if not version:
            errors.append(f"node {name} has an unrecognised Talos version")
        else:
            current = tuple(map(int, version[1][1:].split(".")))
            desired = tuple(map(int, target[1:].split(".")))
            if current > desired or current[0] != desired[0] or desired[1] - current[1] > 1:
                errors.append(f"node {name}: unsupported upgrade path {version[1]} to {target}")
            labels = node["metadata"].get("labels", {})
            if labels.get("plan.upgrade.cattle.io/talos") == plan_hash and version[1] != target:
                errors.append(f"node {name}: submitted upgrade has not reached {target}")
    for db in state["clusters"]:
        name = db["metadata"]["namespace"] + "/" + db["metadata"]["name"]
        spec, status = db["spec"], db.get("status", {})
        # Three instances preserve a second switchover candidate during recovery.
        if (spec.get("instances", 0) < 3 or spec.get("enablePDB", True) is not True
                or spec.get("affinity", {}).get("podAntiAffinityType") != "required"
                or spec.get("affinity", {}).get("enablePodAntiAffinity", True) is not True):
            errors.append(f"CNPG {name}: require >=3 instances, required spreading and PDBs")
        if (not ready(db) or status.get("readyInstances") != spec.get("instances")
                or not status.get("currentPrimary")
                or status.get("targetPrimary") != status.get("currentPrimary")):
            errors.append(f"CNPG {name}: replicas or switchover not settled")
        replicas = [pod for pod in state["pods"]
                    if pod["metadata"].get("namespace") == db["metadata"]["namespace"]
                    and pod["metadata"].get("labels", {}).get("cnpg.io/cluster") == db["metadata"]["name"]
                    and not pod["metadata"].get("deletionTimestamp") and ready(pod)
                    and not any(o.get("kind") == "Job" for o in pod["metadata"].get("ownerReferences", []))]
        placement = {pod.get("spec", {}).get("nodeName") for pod in replicas}
        if len(replicas) != spec.get("instances") or None in placement or len(placement) != len(replicas):
            errors.append(f"CNPG {name}: Ready replicas must actually occupy distinct nodes")
    for obj in state["workloads"]:
        spec, status = obj["spec"], obj.get("status", {})
        desired = (status.get("desiredNumberScheduled", 0) if obj["kind"] == "DaemonSet"
                   else spec.get("replicas", 1))
        actual = status.get("numberReady", 0) if obj["kind"] == "DaemonSet" else status.get("readyReplicas", 0)
        if actual < desired or status.get("observedGeneration", 0) < obj["metadata"].get("generation", 1):
            errors.append(f'{obj["kind"]} {obj["metadata"]["namespace"]}/{obj["metadata"]["name"]} not ready')
    for pod in state["pods"]:
        meta, status = pod["metadata"], pod.get("status", {})
        if status.get("phase") in ("Succeeded", "Failed"):
            continue
        # Jobs have separate lifecycles; the running prepare Pod cannot be Ready.
        if any(owner.get("kind") == "Job" for owner in meta.get("ownerReferences", [])):
            continue
        if meta.get("deletionTimestamp") or not ready(pod):
            errors.append(f'pod {meta["namespace"]}/{meta["name"]} not settled')
    for config in state["webhooks"]:
        for webhook in config.get("webhooks", []):
            if webhook.get("failurePolicy", "Fail") != "Fail":
                continue
            gates_pods = any(
                any(x in ("", "*") for x in rule.get("apiGroups", []))
                and any(x in ("pods", "*", "*/*") for x in rule.get("resources", []))
                and any(x in ("CREATE", "*") for x in rule.get("operations", []))
                for rule in webhook.get("rules", []))
            if gates_pods and selector_matches(webhook.get("namespaceSelector", {}), state["system_labels"]):
                errors.append(f'webhook {webhook["name"]} fails closed on kube-system Pods')
    return errors


class API:
    def __init__(self):
        self.directory = Path("/var/run/secrets/kubernetes.io/serviceaccount")
        self.context = ssl.create_default_context(cafile=str(self.directory / "ca.crt"))

    def get(self, path):
        request = Request("https://kubernetes.default.svc" + path, headers={
            "Authorization": "Bearer " + (self.directory / "token").read_text().strip()})
        with urlopen(request, context=self.context, timeout=10) as response:
            return json.load(response)

    def items(self, path):
        result = self.get(path)
        if not isinstance(result.get("items"), list):
            raise ValueError("API list response has no items")
        if result.get("metadata", {}).get("continue"):
            raise ValueError("incomplete API list response")
        return result["items"]

    def snapshot(self, namespace):
        return {
            "nodes": self.items("/api/v1/nodes"),
            "server_version": self.get("/version"),
            "pods": self.items("/api/v1/pods"),
            "clusters": self.items("/apis/postgresql.cnpg.io/v1/clusters"),
            "workloads": [dict(obj, kind=kind) for resource, kind in (
                ("deployments", "Deployment"), ("statefulsets", "StatefulSet"), ("daemonsets", "DaemonSet"))
                for obj in self.items("/apis/apps/v1/" + resource)],
            "webhooks": sum((self.items("/apis/admissionregistration.k8s.io/v1/" + resource)
                             for resource in ("mutatingwebhookconfigurations", "validatingwebhookconfigurations")), []),
            "system_labels": self.get("/api/v1/namespaces/kube-system")["metadata"].get("labels", {}),
            "plan": self.get(f"/apis/upgrade.cattle.io/v1/namespaces/{namespace}/plans/talos"),
        }


def wait_until_safe(snapshot, target, namespace, *, clock=time.monotonic, sleep=time.sleep,
                    timeout=900, stable=60, poll=15):
    deadline, since, previous = clock() + timeout, None, None
    while clock() < deadline:
        try:
            errors = blockers(snapshot(namespace), target, namespace)
        except Exception as exc:
            # Never log API response bodies, tokens, or secret file contents.
            errors = [f"preflight API/validation failure: {type(exc).__name__}"]
        if errors:
            since = None
        elif since is None:
            since = clock()
        elif clock() - since >= stable:
            print(f"Preflight healthy for {stable}s; allowing one graceful drain", flush=True)
            return
        message = tuple(errors)
        if message != previous:
            print("Waiting: " + ("; ".join(errors[:12]) if errors else "observing stable recovery"), flush=True)
            previous = message
        sleep(poll)
    raise RuntimeError("preflight timed out; node was not cordoned by this prepare check")


def main():
    target = os.environ["SYSTEM_UPGRADE_PLAN_LATEST_VERSION"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", target):
        raise ValueError("target must be a stable Talos version")
    credential = Path("/var/run/secrets/talos.dev/talosconfig")
    if not credential.is_file() or not credential.read_bytes().strip():
        raise RuntimeError("talosconfig credential missing; refusing to drain")
    wait_until_safe(API().snapshot, target, os.environ["POD_NAMESPACE"])


if __name__ == "__main__":
    main()
