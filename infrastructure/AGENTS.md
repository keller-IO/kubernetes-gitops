# infrastructure — AGENTS.md

## Purpose
Cluster-wide platform services. Everything apps depend on.

## Ownership
Owns `base/<component>/` dirs (argocd, cilium, ingress-nginx, cert-manager, cnpg, mariadb-operator, valkey-operator, authentik, monitoring, storage).

## Local Contracts
- **Manifests**: Kustomize + Helm inflation. Namespace = dir name.
- **Operators**: Only here; per-app CRs live under `apps/`.
- **Authentik Blueprints**: Per-app OIDC configs in `base/authentik/blueprints/`.
- **Backup**: Authentik uses platform-level CNPG + Barman (Ceph S3, 30d).

## OIDC Blueprint Onboarding
- **Check OIDC support**: Search official docs for OIDC/SSO.
- **Ask user**: "Soll ich OIDC via Authentik einrichten?"
- **Blueprint Format**:
```yaml
version: 1
metadata:
  name: Homelab <App> OIDC
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: <app>-provider
    identifiers: { client_id: <client-id> }
    attrs:
      name: Provider for <App>
      authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      # ... rest per template
  - model: authentik_core.application
    identifiers: { slug: <app> }
    attrs:
      name: <App>
      provider: !KeyOf <app>-provider
      icon: https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/<app>.svg
```
- **Icon**: Use `dashboardicons.com`.

## Work Guidance
- New component → new `base/<component>/` dir. Update `docs/PRODUCTION-READINESS.md`.
- Verify chart repo URL + version (especially `valkey-operator`).

## Verification
- `just build && just test` (kustomize + kubeconform).

## Child DOX Index
None.
