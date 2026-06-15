# keller.io — Homelab GitOps (Talos + ArgoCD)

Deklaratives, GitOps-gesteuertes Kubernetes-Setup auf Talos Linux. **Aktuell Blaupausen-Phase**:
alle Manifeste sind funktionsbereite Vorlagen mit Platzhaltern (`*.jit.platzhalter`,
`CHANGE ME`, `REPLACE_ME`).

➡️ **Was noch bis Produktion fehlt:** [`docs/PRODUCTION-READINESS.md`](docs/PRODUCTION-READINESS.md)
➡️ **Arbeitsregeln / Architektur:** [`AGENTS.md`](AGENTS.md)

## Stack
ArgoCD (GitOps) · Cilium (CNI) · NGINX Ingress · cert-manager · CloudNativePG (Postgres) ·
mariadb-operator (MySQL für WordPress) · valkey-operator (Cache) · Authentik (OIDC) ·
VictoriaMetrics (Monitoring) · Ceph (RBD/CephFS/S3) · SOPS+age (Secrets) · Renovate.

## Anwendungen
kimai · roundcube (Webmail, externer Mailserver) · collabora · paperless-ngx · forgejo ·
renovate · 3× WordPress · mastodon.

## Layout
```
clusters/main/        ArgoCD entry points (app-of-apps + ApplicationSets)
infrastructure/base/  Plattform-Services (CNI, Ingress, Operatoren, Authentik, Monitoring)
apps/base/            App-Blaupausen (Kustomize + Helm-Inflation)
apps/overlays/main/   Cluster-spezifische Patches (Hosts) — von ApplicationSet auto-deployed
docs/                 Production-Readiness, Runbooks, Learnings
```

## Lokale Validierung
```bash
just build && just test && just lint && just secrets-check
```

## Bootstrap (Kurzform)
1. Talos-Cluster + kubeconfig. 2. ArgoCD installieren. 3. age-Key als `sops-age`-Secret.
4. `kubectl apply -f clusters/main/root-app.yaml`. Details: `docs/PRODUCTION-READINESS.md`.
