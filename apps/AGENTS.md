# apps — AGENTS.md

## Purpose
Application workloads. Functional blueprints with placeholders.

## Ownership
Owns `base/<app>/` (generic) and `overlays/main/<app>/` (cluster patches).

## Local Contracts
- **Apps**: kimai, roundcube, collabora, eurooffice, paperless-ngx, forgejo, renovate, wordpress, mastodon, gatus, kite.
- **Structure**: `kustomization.yaml` + (`values.yaml` | `workload.yaml`) + `database.yaml` + `cache.yaml` + `backup.yaml` + `secret.sops.yaml`.
- **Database**: Postgres (CNPG), MySQL (mariadb-operator).
- **Backup**: Daily to Ceph S3 (30d retention).
- **Secrets**: Must be SOPS-encrypted.

## Work Guidance
- Follow `kubernetes-gitops/AGENTS.md` and Root AGENTS.md.
- Follow "Process for Adding / Updating Apps" in parent docs.
- Update `docs/PRODUCTION-READINESS.md` for every change.

## Verification
- `just build && just test && just secrets-check`.

## Child DOX Index
None.
