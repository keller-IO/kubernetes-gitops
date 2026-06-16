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

## Work Guidance
- Follow `kubernetes-gitops/AGENTS.md` and Root AGENTS.md.
- Maintain intra-infra ordering via sync-waves.

## Verification
- `kubeconform` via CI.

## Child DOX Index
None.
