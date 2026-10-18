# Disposable Argo CD integration pilot

The integration job creates a new, uniquely named Kind cluster and installs the
Argo CD and CloudNativePG chart versions and component values from the tested
Git revision. It exercises Gatus and Goloom; it does not establish compatibility
for the other applications or production storage, ingress, OIDC, or backups.

Run from a repository worktree with Docker available:

```bash
nix develop --command bash scripts/ci/integration/run.sh \
  --mode install --base origin/main --candidate HEAD
nix develop --command bash scripts/ci/integration/run.sh \
  --mode upgrade --base origin/main --candidate HEAD
```

Use immutable base and candidate commit IDs in CI. The candidate should be the
PR merge commit, so the pilot tests the proposed merged repository. Both commits
must already be fetched. Install tests only the candidate; upgrade installs and
syncs the base first, creates a team and uploads media through Goloom's API, then upgrades the controllers and
syncs the candidate into the same cluster. Do not reuse a developer or production
kubeconfig. The runner creates its own temporary config and checks the expected
Kind context and exact localhost API address before every Kubernetes or Helm call.
It also rejects remote Docker endpoints/contexts and Podman remote connections.

For rootless Podman, Kind may need a transient delegated cgroup scope:

```bash
systemd-run --scope --user -p Delegate=yes -- \
  env KIND_EXPERIMENTAL_PROVIDER=podman \
  nix develop --command bash scripts/ci/integration/run.sh \
    --mode upgrade --base origin/main --candidate HEAD
```

This command changes no host services. Hosts without the required cgroup,
container runtime, disk, or memory capacity fail the test. There is no successful
skip or fallback to a render-only test.

The pinned Kubernetes 1.36.1 node image is the official Kind 0.32.0 release image
([release](https://github.com/kubernetes-sigs/kind/releases/tag/v0.32.0)), pinned by
digest. This matches Talos 1.13.4's default Kubernetes version; confirm it against
the actual cluster version when changing the cluster's Talos/Kubernetes target.
Keep `scripts/ci/config.json` and `run.sh` aligned.

The pilot exports each source commit to a temporary directory. It creates a
separate Git history containing only test overlays, synthetic encrypted secrets,
and provenance. A read-only HTTP server inside Kind serves that repository over
the cluster network; no GitHub push credential is involved. Argo CD's actual Git
directory generator, production ApplicationSet template and conditional
multi-source template patch create the Applications. Generated repository SHAs
are immutable, and the Goloom upstream chart tag is resolved to a Git SHA first.
Each phase records the original source SHA and selected chart references in its
provenance artifact.

Gatus retains its production chart, image, resources and environment contract;
its endpoints point only to Goloom inside Kind. Goloom retains its upstream Git
Helm chart, production image, PostgreSQL type, resource/security settings and
existing-claim layout. Its local source includes the real CNPG Cluster and media
PVC, with Kind storage substituted. Production OIDC, ingress, backup jobs and
external monitoring are removed. Its bootstrap administrator and credentials are
synthetic. Each run generates its own age identity; real SOPS encrypts the test
Secrets, and the production Argo repo-server KSOPS init container decrypts them
during reconciliation. Production SOPS documents are never decrypted or copied
into the served repository. The private age identity is deleted on exit.

Success requires both Applications to be Synced and Healthy at the requested
generated SHA, both deployments to complete rollout, both HTTP endpoints to
respond successfully, and Goloom's real application schema/bootstrap user to
exist in PostgreSQL. Upgrade also requires every Goloom media/database PVC UID
to stay unchanged, the API-created team to survive in PostgreSQL, and the uploaded
media to return byte-for-byte identical content after the upgrade. A source-revision annotation
forces Goloom to restart on an upgrade even when its production image is unchanged.
The runner does not claim to test an application-specific data migration or Ceph.

The EXIT trap always attempts diagnostics and deletes only the cluster created
by this run. Artifacts default to `.artifacts/integration/<mode>`; `--artifacts`
or `CI_INTEGRATION_ARTIFACTS` selects the parent directory. They contain pod status, event reasons, Application health and
revision fields, PVC identities, source provenance, cleanup status and result
metadata. They contain no Secret objects, kubeconfig, private age key, environment
dumps or pod logs. Cleanup failure fails the job; use the recorded unique cluster
name to remove a leftover local cluster if the container runtime itself failed.

Fast checks without a cluster still execute real encryption, KSOPS and Helm:

```bash
nix develop --command bash scripts/ci/integration/test-guards.sh
nix develop --command bash scripts/ci/integration/test-prepare.sh
```
