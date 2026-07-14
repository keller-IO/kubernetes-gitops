# infrastructure — AGENTS.md

## Purpose
Cluster-wide platform services. Everything apps depend on.

## Ownership
Owns `base/<component>/` dirs (argocd, cilium, ingress-nginx, cert-manager, cnpg, mariadb-operator, authentik, monitoring, storage, kubernetes-mcp). Cache (Valkey) runs as a standalone instance per app under `apps/base/*/cache.yaml` (no operator). Authentik manifests are legacy migration leftovers; new OIDC work targets external Keycloak.

## Local Contracts
- **Manifests**: Kustomize + Helm inflation. Namespace = dir name.
- **Operators**: Only here; per-app CRs live under `apps/`.
- **OIDC**: External Keycloak Realm `bgt` at `https://auth.savar.de/realms/bgt`; app client secrets live in app SOPS secrets.
- **Backup**: Existing Authentik resources, if still deployed, use platform-level CNPG + Barman (Ceph S3, 30d).

## OIDC Client Onboarding
- **Check OIDC support**: Search official docs for OIDC/SSO.
- **Ask user**: "Soll ich OIDC via Keycloak einrichten?"
- **Keycloak client**: Create or confirm a client in Realm `bgt` on `auth.savar.de`.
- **Redirect URI**: Set the app callback URL for the real production domain.
- **Secret**: Store the Keycloak client secret in the app `secret.sops.yaml`; never commit plaintext.
- **Activation**: Enable app OIDC only after discovery, redirect URI, client ID and secret match.

## Work Guidance
- New component → new `base/<component>/` dir. Update `docs/PRODUCTION-READINESS.md`.
- Verify chart repo URL + version against an actual `helm pull` (CI renders with `--enable-helm`).

## Verification
- `just build && just test` (kustomize + kubeconform).

## Child DOX Index
None.
