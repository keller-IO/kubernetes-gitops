# CI safety and merge contract

GitHub Actions is the leading CI. The workflow runs the locked Nix shell and the
same `just validate` command used locally. Run `just agents-setup` once after a
checkout, then `just validate`. `just integration` runs the fresh-install and
upgrade pilots described in [ci-integration.md](ci-integration.md); CI uses two
separate runners for these scenarios. Missing runtime/tooling is a failed test.
The obsolete Forgejo workflow was removed to avoid a second, divergent gate.

## Required checks

`ci-required` depends on static validation and the entire integration matrix. It
requires both jobs to report success: failure, cancellation, skip or absence
fails the gate. PRs test the merge commit; merge queues trigger `merge_group` too.

`.github/main-ruleset.json` is the reviewed REST payload for repository ruleset
25293233. It selects `refs/heads/main`, requires a PR and a successful
`ci-required` check from the GitHub Actions app (15368), merges through the
merge queue, and blocks deletion and force pushes with no bypass actors. The
payload alone does not change GitHub. Apply after the new check has been
reported on a PR:

```bash
gh api --method PUT repos/keller-IO/kubernetes-gitops/rulesets/25293233 \
  --input .github/main-ruleset.json
gh api --method PATCH repos/keller-IO/kubernetes-gitops -F allow_auto_merge=true
gh api repos/keller-IO/kubernetes-gitops/rules/branches/main
```

PR branches do not have to be up to date with `main`. The merge queue tests
each PR on top of current `main` (plus queued PRs ahead of it) via
`merge_group` and only then merges, so `main` stays green without manual
rebases. Renovate rebases only on conflicts (`rebaseWhen: conflicted`) and
enqueues automerge PRs through GitHub auto-merge.

This intentionally blocks older PRs until their branch includes the new workflow.
Required review count stays zero for otherwise eligible automated Renovate PRs.
Existing Renovate restrictions keep stateful apps/controllers manual; CI workflow
and GitOps control-plane dependencies also stay manual. Goloom is explicitly
included as a stateful app. Digest/pin/patch automerge is limited to the named
stateless leaf apps; new or unclassified apps default to manual review. Review changes to workflows, check scripts,
schema pins and known-gap baselines as security-sensitive code before merging.
This is a repository review policy, not an enforced per-path approval rule.

## Render and schemas

`scripts/ci/render-all.sh OUTPUT` requires an empty output directory. It copies
sources, replaces all SOPS payloads with synthetic values, encrypts the full YAML
streams with a fresh age identity, and invokes real KSOPS. It overrides caller age
key variables and never decrypts production payloads. The private identity and
source copy are deleted on exit; only synthetic rendered output is retained.
This verifies generator execution, key names and resource structure, not the
correctness of production passwords, DSNs or encrypted configuration contents.

Every selected app/infra directory must have a Kustomization. Cluster Application,
ApplicationSet and AppProject documents are validated too. Tonu and Flurfunk are
explicit frozen external-source exceptions in
`scripts/ci/known-gaps/external-applications.json`: their manifests and mutable
`main` source revisions are outside this repository's CI. A changed spec or a
new external Application fails until its rendering is integrated or the reviewed
contract is deliberately changed; this gate does not prove those external apps
are deployable.

The target is Kubernetes **1.36.1**, matching the documented default in
[Talos 1.13.4 constants](https://github.com/siderolabs/talos/blob/v1.13.4/pkg/machinery/constants/constants.go).
Actual production version was not reachable during implementation; confirm it
read-only when the proxy is available. The exact schema catalog commit,
Kubernetes OpenAPI content hash and supplemental schema hashes live in
`scripts/ci/config.json`. Most custom schemas come from the rendered CRDs.
Cilium installs CRDs at runtime, so its supplemental schemas use the exact chart
version plus content hashes. Prometheus ServiceMonitor/PodMonitor schemas are
pinned to operator 0.92.0, whose official client dependency is Kubernetes 0.36.2.

Unknown GVKs, missing schemas, malformed objects and content hash mismatches fail.
For Kubernetes/Cilium bumps, review the matching upstream schema sources and
refresh hashes; never suppress the failure with `-ignore-missing-schemas`.
JSON Schema does not execute CEL, admission webhooks or operator controllers.

Existing gap: VictoriaMetrics stack 0.95.2 has no
`prometheus-operator-crds` chart dependency despite the configured values flag.
Supplemental schemas validate the six rendered ServiceMonitor/PodMonitor CRs;
they neither install the CRDs nor establish their presence in production.

## Retention and security debt

Rendered application PVCs require exact Argo `Prune=false,Delete=false` options.
Spaces around `=` and duplicate values are rejected. All 14 previously
unprotected PVCs now carry both options through their manifests or native Helm
annotation values; `known-gaps/unprotected-pvcs.txt` has no exceptions. Verify
the annotations have synced before migrating chart sources. They protect against
Argo prune and application deletion, not namespace deletion or storage failure.
StatefulSet-created claim templates are not directly tracked/pruned by Argo and
need separate retention review when changing StatefulSets.

Trivy uses the locked dev-shell version and a digest-pinned checks bundle in
`security-config.json`. The initial 277 HIGH/CRITICAL misconfigurations are
recorded as 243 exact target/check/message/count exceptions in
`known-gaps/security.json`, expiring **2027-01-18**. These are existing security
debt, not approved defaults. New, changed, increased, expired or stale findings
fail; fixing a finding requires deleting its exception. Review checker bundle
updates and regenerate only entries that still apply, never an automatic new
baseline for all findings. Secret scanning has no finding exceptions and exits
nonzero for detected secrets. Local generated agent/tool caches and integration
artifacts are excluded from that scan; `.rulesync` sources remain included.

## Automation boundary

A green gate covers the full static render and the Gatus/Goloom pilots. It does
not authorize automatic Talos/Cilium/Ceph upgrades, prove all apps healthy, or
prove a backup can be restored. The next stage is production revision/health
observation with automatic merges paused on failure, plus isolated restore tests
against off-cluster backups. Keep controller/database changes under manual review
until their own integration and recovery paths are covered. Reverting Git does
not undo an irreversible database migration.
