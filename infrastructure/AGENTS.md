# infrastructure — AGENTS.md

## Purpose

Cluster-wide platform services. Everything apps depend on.

## Ownership

Owns `base/<component>/` dirs. Each is a Kustomize app with Helm inflation (`helmCharts:`) +
optional plain resources. `overlays/main/` holds cluster patches and the disaster-recovery overlay.

## Local Contracts

- Components: `argocd`, `cilium`, `ingress-nginx`, `cert-manager`, `cnpg`, `mariadb-operator`,
  `valkey-operator`, `authentik`, `monitoring`, `storage`.
- Each component dir = `kustomization.yaml` (+ `values.yaml` for charts). Namespace = dir name,
  set by the ApplicationSet (`appset-infrastructure.yaml`).
- Operators only here; per-app CRs (`Cluster`, `MariaDB`, `Valkey`) live under `apps/`.
- Exception: `authentik/` runs its own CNPG `Cluster` + `ScheduledBackup` (`postgres.yaml`,
  `backup.yaml`) since it is platform-level. Backup contract = same as apps (Ceph S3, 30d).
- `authentik/blueprints/*` — per-app OIDC blueprints (`!Find`/`!KeyOf` custom tags, not standard YAML).
  Format and onboarding rules: root AGENTS.md "OIDC / Authentik Blueprint Onboarding".
- `storage/` assumes Ceph already exists; only declares StorageClasses (`ceph-rbd`, `ceph-fs`) + OBC.
- Chart versions pinned with `# renovate: helm`.

## Work Guidance

- New component → new `base/<component>/` dir; add open production steps to
  `docs/PRODUCTION-READINESS.md`. No `clusters/` edit needed (generator auto-discovers).
- Verify chart repo URL + version against upstream before first sync (esp. `valkey-operator` CRD schema).

## Verification

- Local: `just build && just test` (kustomize build + kubeconform). CI runs same.

## Child DOX Index

None.
