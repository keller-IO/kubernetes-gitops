# apps — AGENTS.md

## Purpose

Application workloads. Functional blueprints with placeholders.

## Ownership

Owns `base/<app>/` (generic) and `overlays/main/<app>/` (cluster patches). The apps
ApplicationSet creates one ArgoCD Application per overlay dir.

## Local Contracts

- Apps: `kimai`, `roundcube`, `collabora`, `paperless-ngx`, `forgejo`, `renovate`, `wordpress`
  (base shared by overlays `wordpress-1/2/3`), `mastodon`.
- Standard app dir shape: `kustomization.yaml` + (`values.yaml` for Helm | `workload.yaml` for raw)
  + `database.yaml` + `cache.yaml` + `backup.yaml` + `secret.sops.yaml` + ingress (chart or `ingress.yaml`).
- DB: Postgres → CNPG `Cluster` (basic-auth secret); MySQL → `MariaDB` CR. WordPress + Kimai use MariaDB.
- DB backup mandatory: CNPG → `backup.barmanObjectStore` in `database.yaml` + `ScheduledBackup` in
  `backup.yaml`; MariaDB → `Backup` CR in `backup.yaml`. Daily → Ceph S3, 30d retention.
  S3 creds = `<app>-backup-s3` secret in `secret.sops.yaml`.
- Cache: one `Valkey` CR per app.
- Secrets: every `secret.sops.yaml` must be SOPS-encrypted before commit. DB-owner password ==
  app-env password.
- Overlay = thin `kustomization.yaml` referencing `../../../base/<app>`; patches host/site only.
- WordPress instances share one base; identical resource names are safe (separate namespaces).
- Ingress annotations: `nginx.org/*` per root AGENTS.md conventions. Hosts use `*.jit.platzhalter`.
- Host reference list: `overlays/main/cluster-config.yaml` (not a kustomize dir, ignored by generator).

## Work Guidance

- New app → follow root AGENTS.md "Process for Adding / Updating Apps". Append open steps to
  `docs/PRODUCTION-READINESS.md` section 14 table (mandatory).
- OIDC web apps → run Authentik blueprint onboarding; keep `client_secret` identical in blueprint
  and app secret.

## Verification

- Local: `just build && just test && just secrets-check`. CI runs same + yamllint.

## Child DOX Index

None.
