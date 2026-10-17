---
name: add-app
description: Onboard a new application into this GitOps tree (kustomize base + overlay + database + cache + backup + SOPS secret) or audit an existing app for missing contracts. Use when the user adds an app, says "neue App", "app onboarden", or an apps/base/<app>/ directory appears incomplete.
targets: ["*"]
---

# App onboarding (kubernetes-gitops)

All paths are repo-root-relative. Work on a feature branch, finish with `just validate`.

## 1. Prepare
- Read the app's official chart/docs: version, values schema, required dependencies.
- Copy an existing precedent under `apps/base/` (kimai, paperless-ngx are good models).

## 2. Create the base: `apps/base/<app>/`
- `kustomization.yaml` with `helmCharts:` inflation + `values.yaml`.
  Pin images explicitly — no `latest`, no `imagePullPolicy: Always`.
- `namespace.yaml`: ship it explicitly AND label
  `pod-security.kubernetes.io/enforce: baseline` (+ `audit`/`warn`). Relying on
  ArgoCD's `CreateNamespace=true` yields a namespace with no PodSecurity labels
  (the crowdsec incident, see `infrastructure/AGENTS.md`). CI checks this against
  `scripts/ci/known-gaps/missing-namespace.txt`.
- `database.yaml` (CNPG Postgres / mariadb-operator MySQL): **must** set
  `spec.resources` (requests+limits) **and** pin `spec.image`/`spec.imageName`.
  Both are CI-enforced via `scripts/ci/known-gaps/` — and new CRs get no free pass.
  Size requests from a measured `kubectl top`, never a guess.
- `cache.yaml` (standalone Valkey per app), `backup.yaml` (daily to Ceph S3, 30d).
- `secret.sops.yaml`: SOPS-encrypted (`just encrypt <file>`), never plaintext.
- No HPA unless genuinely required and CPU-based. `scripts/ci/check-hpa.sh` fails
  on any unallowlisted HPA and never allows a memory target
  (`known-gaps/hpa-allowlist.txt`); see `docs/learnings/collabora-hpa-runaway.md`.

## 3. Create the overlay: `apps/overlays/main/<app>/`
- `kustomization.yaml` referencing the base + cluster-specific patches.
- Ingress uses `nginx.org/*` annotations; hosts belong in `cluster-config.yaml`.

## 4. Finish (both mandatory)
- Update `docs/PRODUCTION-READINESS.md`.
- Run `just validate` (inside `nix develop`).
- Inspect the **rendered** manifests before committing — values files lie, the
  render does not. Use the `manifest-inspector` subagent or
  `bash scripts/render.sh <dir>`. A chart can silently ignore a value or ship an
  HPA you never asked for.

## OIDC onboarding
Do not start this on your own. First confirm or create a Keycloak client in realm
`bgt` (ask the user), put the client secret into the app `secret.sops.yaml`, and
enable app OIDC only after a client/secret match is confirmed.
