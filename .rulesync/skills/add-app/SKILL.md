---
name: add-app
description: Onboard a new application into this GitOps tree (kustomize base + overlay, suitable data storage, backup, and SOPS secrets) or audit an existing app for missing contracts. Use when the user adds an app, says "neue App", "app onboarden", or an apps/base/<app>/ directory appears incomplete.
targets: ["*"]
---

# App onboarding (kubernetes-gitops)

All paths are repo-root-relative. Work on a feature branch, finish with `just validate`.

## 1. Prepare
- Read the app's official chart/docs: version, values schema, required dependencies.
- Check which database engines the app officially supports. Choose the first
  suitable option in this order: PostgreSQL with CNPG (`expense-tracker`),
  MySQL/MariaDB with mariadb-operator (`matomo`), then SQLite (`goloom`).
  Document a concrete reason for deviating from this order; SQLite remains an
  exception. Check a precedent's current gaps before copying it.

## 2. Create the base: `apps/base/<app>/`
- `kustomization.yaml` with the required resources; use `helmCharts:` and
  `values.yaml` when this app is chart-based.
  Pin images explicitly — no `latest`, no `imagePullPolicy: Always`.
- `namespace.yaml`: ship it explicitly. Choose PodSecurity labels for the
  rendered workload; use `restricted` where possible and explain any weaker
  level. Relying on
  ArgoCD's `CreateNamespace=true` yields a namespace with no PodSecurity labels
  (the crowdsec incident, see `infrastructure/AGENTS.md`). CI checks this against
  `scripts/ci/known-gaps/missing-namespace.txt`.
- If a database CR is needed, put it in `database.yaml` (CNPG PostgreSQL or
  mariadb-operator MariaDB): set `spec.resources` with requests and limits and
  pin CNPG `spec.imageName` or MariaDB `spec.image`. CI checks the presence of
  resources and image pins against `scripts/ci/known-gaps/`; new CRs get no
  free pass. Start with measurements from a comparable workload and adjust
  after deployment using read-only metrics.
- Add `cache.yaml` with standalone Valkey if the app requires it. If Valkey is
  merely optional, ask the user whether to include it before adding it.
  Configure daily backups to off-cluster Garage S3, normally with 30d
  retention; use the backend-specific pattern in
  `docs/runbooks/backup-restore.md` (including SQLite apps). Record a
  deliberate longer retention period when needed.
- `secret.sops.yaml`: SOPS-encrypted (`just encrypt <file>`), never plaintext.
- No HPA unless genuinely required and CPU-based. `scripts/ci/check-hpa.sh` fails
  on any unallowlisted HPA and never allows a memory target
  (`scripts/ci/known-gaps/hpa-allowlist.txt`); see
  `docs/learnings/collabora-hpa-runaway.md`.

## 3. Create the overlay: `apps/overlays/main/<app>/`
- `kustomization.yaml` referencing the base + cluster-specific patches.
- Ingress uses `nginx.org/*` annotations; hosts belong in
  `apps/overlays/main/cluster-config.yaml`.

## 4. Finish
- Update `docs/PRODUCTION-READINESS.md`.
- Run `just validate` (inside `nix develop`).
- Run `scripts/ci/check-hpa.sh` separately; the CI job runs it, but
  `just validate` does not.
- Inspect the **rendered** manifests before committing — values files lie, the
  render does not. Use the `manifest-inspector` subagent or
  `bash scripts/render.sh <dir>`. A chart can silently ignore a value or ship an
  HPA you never asked for.

## OIDC onboarding
Do not start this on your own. First confirm or create a Keycloak client in realm
`bgt` (ask the user), put the client secret into the app `secret.sops.yaml`, and
enable app OIDC only after a client/secret match is confirmed.
