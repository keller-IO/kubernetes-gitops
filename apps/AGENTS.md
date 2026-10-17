# apps — AGENTS.md

## Purpose
Application workloads. Functional blueprints with placeholders.

## Ownership
Owns `base/<app>/` (generic) and `overlays/main/<app>/` (cluster patches).

## Local Contracts
- **Apps**: kimai, roundcube, collabora, eurooffice, paperless-ngx, forgejo, renovate, wordpress, mastodon, gatus, kite, ciso-assistant.
- **Structure**: `kustomization.yaml` plus a chart/values or workload manifest,
  storage and cache manifests as needed, backup, and SOPS-encrypted secrets.
- **Database**: Choose the first suitable option: PostgreSQL (CNPG),
  MySQL/MariaDB (mariadb-operator), then SQLite. Document deviations; SQLite
  remains an exception. A `database.yaml` operator CR needs
  `spec.resources` + a pinned image — see root `AGENTS.md`, CI-enforced.
- **Cache**: Use Valkey when required by the app. Ask the user before adding it
  when it is optional.
- **Namespace**: ship `namespace.yaml` explicitly with PodSecurity labels suited
  to the workload — see `infrastructure/AGENTS.md`, CI-enforced.
- **Backup**: Daily to off-cluster Garage S3 (normally 30d retention; see
  `docs/runbooks/backup-restore.md`).
- **Secrets**: Must be SOPS-encrypted.

## Work Guidance
- Follow `kubernetes-gitops/AGENTS.md` and Root AGENTS.md.
- Follow "Process for Adding / Updating Apps" in parent docs.
- Update `docs/PRODUCTION-READINESS.md` for every change.

## Verification
- `just build && just test && just secrets-check`.

## Child DOX Index
None.
