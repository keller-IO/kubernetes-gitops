# clusters — AGENTS.md

## Purpose

ArgoCD entry points for the `main` cluster. Bootstraps the whole GitOps tree.

## Ownership

Owns the app-of-apps root, AppProjects, and the two ApplicationSets that generate one
ArgoCD Application per `infrastructure/base/*` and `apps/overlays/main/*`.

## Local Contracts

- `root-app.yaml` — app-of-apps; applied once after ArgoCD install (sync-wave `-10`).
- `projects.yaml` — AppProjects `infrastructure`, `apps`.
- `appset-infrastructure.yaml` — git-directory generator over `infrastructure/base/*`, sync-wave `-5`.
- `appset-apps.yaml` — git-directory generator over `apps/overlays/main/*`, sync-wave `5`.
- All four files carry `repoURL` placeholders → must be set to the real repo URL before apply.
- ApplicationSets reference `plugin.name: kustomize-helm` → repo-server needs the CMP + KSOPS
  (see `infrastructure/base/argocd/`).
- Adding a new infra component or app dir needs no edit here — the generators pick it up.

## Work Guidance

- Keep intra-infra ordering correct via sync-waves; CNI/CRDs/operators before dependent apps.

## Verification

- `kustomize build --enable-helm` is not used here (plain manifests). `kubeconform` via CI.

## Child DOX Index

None.
