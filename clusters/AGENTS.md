# clusters — AGENTS.md

## Purpose
ArgoCD entry points for the main cluster. Bootstraps the GitOps tree.

## Ownership
Owns `root-app.yaml`, `projects.yaml`, and `appset-*` generators.

## Local Contracts
- **ArgoCD Root**: `root-app.yaml` (sync-wave -10).
- **Projects**: `infrastructure`, `apps`.
- **Generators**: `appset-infrastructure.yaml` (infra), `appset-apps.yaml` (apps).
- **Plugin**: Uses `kustomize-helm` CMP.
- **Defaulted fields cause permanent OutOfSync.** A field the API server or an
  operator fills in (e.g. `volumeMode: Filesystem`) must either be written into Git
  explicitly, when the value is fixed, or listed under `ignoreDifferences` — and
  `ignoreDifferences` belongs **only** in these two `appset-*.yaml` templates, never on
  a generated `Application` (the controller overwrites that within a second). CI fails
  on any `ignoreDifferences` found outside this pair of files
  (`scripts/ci/guardrails.sh`). See `docs/learnings/argocd-dauerhaft-outofsync.md`.

## Work Guidance
- Follow `kubernetes-gitops/AGENTS.md` and Root AGENTS.md.
- Maintain intra-infra ordering via sync-waves.

## Verification
- `kubeconform` via CI.

## Child DOX Index
None.
