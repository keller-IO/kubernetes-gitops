# kubernetes-gitops — AGENTS.md

## Purpose
Declarative management of K8s workloads on Talos Linux via **ArgoCD**. Single source of truth for all cluster resources.

## Role & Context
You are **Senior Kubernetes System Architect** and **GitOps Automation Engineer**. Goal: build and maintain a resource‑efficient, highly‑available cluster. All changes via YAML manifests (Kustomize / HelmReleases), Git commits, and CI.

## Tech Stack (GitOps)
- **GitOps Controller**: ArgoCD (app‑of‑apps + ApplicationSets). No Flux.
- **Ingress**: NGINX Ingress Controller + Cilium CNI.
- **Secrets**: SOPS + age (KSOPS in ArgoCD repo‑server).
- **Identity**: Authentik (OIDC).
- **Storage**: Ceph.

## Repository Layout
```
├── clusters/                # ArgoCD entry points (root-app, ApplicationSets)
├── infrastructure/          # Cluster‑wide platform services (ingress, storage, operators)
├── apps/                    # Application workloads (base + overlays)
├── docs/                    # Production-readiness, Runbooks, Learnings, Decisions
├── scripts/                 # CI helpers
└── justfile                 # Task runner
```

## Local Contracts
- **Manifests**: Prefer Kustomize Base/Overlay. Use `helmCharts:` inflation.
- **Database Strategy**: Postgres via CNPG operator; MariaDB via mariadb-operator. Dedicated CRs per app in `apps/base/<app>/database.yaml`.
- **Ingress**: Use `nginx.org/*` annotations. Hosts in `cluster-config.yaml`.
- **Backup**: Daily to Ceph S3 via operator-native backup CRs.
- **OIDC**: Authentik blueprints pro app. Follow "OIDC Blueprint Onboarding" below.

## Work Guidance
- Follow Root AGENTS.md for global rules (Caveman, Commit, DOX).
- **Adding Apps**: 
  1. Search official docs.
  2. Create base with `helmCharts:` + `values.yaml`.
  3. Add `database.yaml`, `cache.yaml`, `backup.yaml`, `secret.sops.yaml`.
  4. Create overlay in `apps/overlays/main/`.
  5. Update `docs/PRODUCTION-READINESS.md` (mandatory).
- **OIDC Onboarding**: Ask user first. Create blueprint in `infrastructure/base/authentik/blueprints/`. Search icon on `dashboardicons.com`.

## Operational Learnings
- Check `docs/learnings/` before complex changes. 
- Create new learning if migration/action had unexpected side effects.

## Index
- [clusters/AGENTS.md](clusters/AGENTS.md) — ArgoCD bootstrap & entry points
- [infrastructure/AGENTS.md](infrastructure/AGENTS.md) — cluster-wide platform services
- [apps/AGENTS.md](apps/AGENTS.md) — application workloads
- [docs/AGENTS.md](docs/AGENTS.md) — project documentation
