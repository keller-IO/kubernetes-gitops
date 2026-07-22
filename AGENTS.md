# kubernetes-gitops — AGENTS.md

## Purpose
Declarative management of K8s workloads on Talos Linux via **ArgoCD**. Single source of truth for all cluster resources.

## Role & Context
You are **Senior Kubernetes System Architect** and **GitOps Automation Engineer**. Goal: build and maintain a resource‑efficient, highly‑available cluster. All changes via YAML manifests (Kustomize / HelmReleases), Git commits, and CI.

## Tech Stack (GitOps)
- **GitOps Controller**: ArgoCD (app‑of‑apps + ApplicationSets). No Flux.
- **Ingress**: NGINX Ingress Controller + Cilium CNI.
- **Secrets**: SOPS + age (KSOPS in ArgoCD repo‑server).
- **Identity**: External Keycloak (OIDC), Realm `bgt` at `https://auth.savar.de/realms/bgt`.
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
- **OIDC**: Use external Keycloak clients and app SOPS secrets. Do not add new Authentik blueprints unless the architecture decision changes again.

## Work Guidance
- Follow Root AGENTS.md for global rules (Caveman, Commit, DOX).
- **Adding Apps**: 
  1. Search official docs.
  2. Create base with `helmCharts:` + `values.yaml`.
  3. Add `database.yaml`, `cache.yaml`, `backup.yaml`, `secret.sops.yaml`.
  4. Create overlay in `apps/overlays/main/`.
  5. Update `docs/PRODUCTION-READINESS.md` (mandatory).
- **OIDC Onboarding**: Ask user first. Create or confirm a Keycloak client in Realm `bgt`, set app redirect URIs, then store client secrets in the app `secret.sops.yaml`. Enable app OIDC only after a client/secret match is confirmed.

## External Infrastructure (DNS & Public Routing)
- **Public path**: Router `87.191.135.42` (80/443) → `.15`-Traefik (192.168.2.15, TLS-Terminierung) → Cluster-LB **192.168.2.246** (nginx-inc). Externe Ingresses daher HTTP-only (kein `spec.tls`), sonst Redirect-Loop. Cutover-Ziel: Router direkt → .246, dann Cluster-TLS je Domain ergänzen.
- **DNS-Master**: `dns01.jit-creatives.de` (88.198.107.13), BIND9. Zonen unter `/etc/bind/dom/<domain>.db` mit `$INCLUDE`-Fragmenten (`.a`, `.aaaa`, `.cn`, `.mx`, `.ns`, `.rr`); DNSSEC inline-signing.
  Workflow: Fragment editieren → Serial in `.db` bumpen (YYYYMMDDNN) → `named-checkzone` → `rndc reload <zone>`.
- **⚠️ Delegation prüfen, bevor du dns01 editierst**: Nicht jede Zone auf dns01 ist öffentlich autoritativ. Z. B. ist `gemeinsam-fuer-halbe.de` an der Registry zu **Cloudflare** delegiert (native CF-Zone, kein AXFR von dns01) — Änderungen dort zusätzlich im CF-Dashboard nötig. Check: `dig +noall +authority NS <zone> @a.nic.de`.
- **Secondaries** von dns01: dns02, dns03, ClouDNS (pns31–34 — auch Basis für cert-manager DNS-01).
- **web03.jit-creatives.de** (88.198.107.11): Alt-Webserver, serviert nur noch Apex-301-Redirects auf www.
- **Betriebsdoku** immer zusätzlich nach cfgmgmt01 kopieren: `192.168.23.19:/root/ansible/kellerio-docs/`.

## Operational Learnings
- Check `docs/learnings/` before complex changes. 
- Create new learning if migration/action had unexpected side effects.

## Index
- [clusters/AGENTS.md](clusters/AGENTS.md) — ArgoCD bootstrap & entry points
- [infrastructure/AGENTS.md](infrastructure/AGENTS.md) — cluster-wide platform services
- [apps/AGENTS.md](apps/AGENTS.md) — application workloads
- [docs/AGENTS.md](docs/AGENTS.md) — project documentation
