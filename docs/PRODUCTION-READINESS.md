# Production Readiness — Offene Schritte bis zum Go-Live

Status: **Blaupausen-Phase.** Alle Manifeste sind funktionsbereite Vorlagen mit
Platzhaltern (`CHANGE ME`, `REPLACE_ME`, Domain `*.jit.services`). Dieses Dokument
listet pro Bereich, was noch zu erledigen ist, **welche Dateien** betroffen sind und
gibt **je Section ein Beispiel**.

Konventionen:
- `CHANGE ME`  → nicht-geheimer Platzhalter (Domain, StorageClass, ID).
- `REPLACE_ME` → Geheimnis. Nur in `*.sops.yaml`, **vor Commit verschlüsseln**.
- Suche global: `grep -rn "CHANGE ME\|REPLACE_ME\|jit.services" .`

Schnellstart-Checkliste (Reihenfolge):
1. [Bootstrap & Talos](#1-bootstrap--talos) → 2. [GitOps / ArgoCD](#2-gitops--argocd) →
3. [Secrets](#3-secrets-sops--age) → 4. [Netzwerk/Ingress/DNS](#4-netzwerk-ingress--dns) →
5. [Storage](#5-storage-ceph) → 6. [TLS](#6-tls--cert-manager) →
7. [Datenbanken](#7-datenbanken) → 8. [Cache](#8-cache-valkey) →
9. [Identity/OIDC](#9-identity--oidc-authentik) → 10. [Observability](#10-observability--alerting) →
11. [Backup/DR](#11-backup--disaster-recovery) → 12. [CI & Renovate](#12-ci--renovate) →
13. [Mail](#13-mail-extern) → 14. [Pro-App-TODOs](#14-pro-app-todos).

---

## 1. Bootstrap & Talos

**Dateien:** (Talos-Config liegt außerhalb dieses Repos — `talosctl`/`talconfig`),
`infrastructure/base/cilium/values.yaml`

**Offen:**
- [ ] Talos-Cluster provisionieren (control-plane + worker), `kubeconfig` exportieren.
- [ ] Nix Dev-Shell bereitstellen (`flake.nix`/`shell.nix`) mit `kubectl, kustomize,
      helm, sops, age, kubeconform, just, argocd` — wird in AGENTS.md vorausgesetzt, fehlt noch.
- [ ] `k8sServiceHost`/`k8sServicePort` in Cilium auf KubePrism/VIP setzen.

**Beispiel** (`infrastructure/base/cilium/values.yaml`):
```yaml
k8sServiceHost: 127.0.0.1   # Talos KubePrism
k8sServicePort: 7445
kubeProxyReplacement: true
```

---

## 2. GitOps / ArgoCD

**Dateien:** `clusters/main/*.yaml`, `infrastructure/base/argocd/*`

**Offen:**
- [ ] `repoURL` in `clusters/main/root-app.yaml`, `appset-infrastructure.yaml`,
      `appset-apps.yaml` auf echte Repo-URL setzen (aktuell `git.f4mily.net/keller.io/keller.io.git`).
- [ ] ArgoCD wird per Terraform installiert (`infrastructure/tofu .../argocd.tf`), das den
      Bootstrap-Root-App deployt. `clusters/main/root-app.yaml` ist die manuelle Alternative.
- [ ] Intra-Infra-Reihenfolge prüfen: CNI/CRDs/Operatoren vor Apps (sync-waves grob gesetzt,
      ggf. verfeinern: cilium → cert-manager/CRDs → operatoren → authentik/monitoring → apps).

**Secret-Handling (KEIN CMP-Plugin):** ArgoCD nutzt **nativen kustomize** mit
`kustomize.buildOptions: --enable-helm --enable-alpha-plugins --enable-exec` und dem
**KSOPS-Exec-Generator**. Jede Komponente mit Secret hat ein `secret-generator.yaml`
(`kind: ksops`), das die zugehörige `*.sops.yaml` beim Build entschlüsselt. Der repo-server
bekommt `ksops`+`kustomize` (Init-Container) und den age-Key (`argocd-sops-age`). Die
AppSets nutzen **kein** `plugin:` mehr. Konfiguration muss mit Terraform `argocd.tf`
übereinstimmen. Wichtig: `*.sops.yaml` müssen **verschlüsselt** sein, sonst schlägt der
Build der App fehl (`sops metadata not found`).

---

## 3. Secrets (SOPS + age)

**Dateien:** `.sops.yaml`, jede `**/secret.sops.yaml`, `infrastructure/base/argocd/values.yaml`

**Offen:**
- [ ] age-Keypair erzeugen: `age-keygen -o age.agekey` (privaten Key **nie** committen).
- [ ] Public Key in `.sops.yaml` (`age:` Zeile) eintragen.
- [ ] age-Key als Secret in den Cluster: `kubectl -n argocd create secret generic sops-age
      --from-file=keys.txt=age.agekey`.
- [ ] **Alle** `*.sops.yaml` mit echten Werten füllen und verschlüsseln:
      `just encrypt path/to/secret.sops.yaml` (oder `sops --encrypt --in-place`).
- [ ] CI-Gate aktiv halten (`just secrets-check`) — verhindert Klartext-Commits.

**Beispiel:**
```bash
age-keygen -o age.agekey                 # erzeugt pub+priv
# .sops.yaml: age: age1xxx... (der "Public key:" aus der Datei)
sops --encrypt --in-place apps/base/kimai/secret.sops.yaml
```

---

## 4. Netzwerk, Ingress & DNS

**Dateien:** `infrastructure/base/ingress-nginx/values.yaml`, `infrastructure/base/cilium/values.yaml`,
alle `**/ingress.yaml` & Chart-`values.yaml` (`hosts:`), `apps/overlays/main/cluster-config.yaml`

**Offen:**
- [x] **Domain festgelegt**: `jit.services` — `cluster-config.yaml` + alle Manifeste aktualisiert.
- [ ] LoadBalancer-IP-Quelle wählen: Cilium LB-IPAM **oder** MetalLB-Pool → Ingress-Service
      bekommt externe IP.
- [ ] DNS-Records (A/AAAA bzw. CNAME) für alle Hosts aus `cluster-config.yaml` auf die LB-IP.
- [ ] Wildcard-DNS `*.DEINE-DOMAIN.tld` optional für weniger Pflege.

**Beispiel** — Cilium LB-IPAM-Pool:
```yaml
apiVersion: cilium.io/v2alpha1
kind: CiliumLoadBalancerIPPool
metadata: { name: main-pool }
spec:
  blocks:
    - { start: 192.0.2.20, stop: 192.0.2.40 }   # CHANGE ME
```

---

## 5. Storage (Ceph)

**Dateien:** `infrastructure/base/storage/*`, jedes `storageClassName:` / `storageClass:` in den Apps

**Offen:**
- [ ] Existierende Ceph-StorageClass-Namen verifizieren und Manifeste angleichen
      (`ceph-rbd` = RWO, `ceph-fs` = RWX). Doppelte Klassen löschen, wenn Ceph sie schon liefert.
- [ ] S3/RGW: Bucket-StorageClass-Namen für `ObjectBucketClaim` setzen (`ceph-bucket`).
- [ ] RWX (CephFS) dort bestätigen, wo mehrere Replicas teilen (paperless media, wordpress wp-content).
- [ ] Default-StorageClass festlegen (aktuell `ceph-rbd`).

**Beispiel** — S3-Bucket via OBC (siehe `infrastructure/base/storage/objectbucket-example.yaml`):
```yaml
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata: { name: mastodon-media, namespace: mastodon }
spec:
  generateBucketName: mastodon-media
  storageClassName: ceph-bucket   # CHANGE ME
```

---

## 6. TLS / cert-manager

**Dateien:** `infrastructure/base/cert-manager/*`, alle `cert-manager.io/cluster-issuer` Annotations

DNS-01 läuft über **ClouDNS**. Da ClouDNS kein nativer cert-manager-Provider ist, wird der
ACME-Webhook `cert-manager-webhook-cloudns` mitausgerollt (Chart in `kustomization.yaml`,
Werte in `cloudns-webhook-values.yaml`).

`savar.de` nutzt zusätzlich DNS-01 via RFC2136/TSIG gegen `dns01.jit-creatives.de`.
Das Secret liegt in `infrastructure/base/cert-manager/rfc2136-tsig.sops.yaml`; der
Solver ist im `letsencrypt-prod`-ClusterIssuer auf `dnsZones: [savar.de]` begrenzt.

**Offen:**
- [ ] ClouDNS-Credentials in `cluster-issuer.sops.yaml` setzen + verschlüsseln
      (`auth_id`/`auth_password`). Empfohlen: zonen-beschränkter **sub-auth-id**-Nutzer.
- [ ] `clouDNS.authIdType` in `cloudns-webhook-values.yaml` zum Credential passend setzen
      (`sub-auth-id` oder `auth-id`).
- [ ] `groupName` in Issuer **und** Webhook-Werten müssen identisch sein (`acme.jit.services`).
- [ ] `email:` und `dnsZones:` auf echte Werte.
- [ ] Optional Staging-Issuer für Testläufe (Let's-Encrypt-Ratelimits).

**Beispiel** (`infrastructure/base/cert-manager/cluster-issuer.sops.yaml`):
```yaml
spec:
  acme:
    email: admin@DEINE-DOMAIN.tld
    solvers:
      - dns01: { webhook: { groupName: acme.jit.services, solverName: cloudns } }
```

---

## 7. Datenbanken

**Postgres (CNPG):** `infrastructure/base/cnpg/`, `apps/base/{roundcube,paperless-ngx,forgejo,mastodon,mailman}/database.yaml`, `infrastructure/base/authentik/postgres.yaml`
**MariaDB (Operator):** `infrastructure/base/mariadb-operator/`, `apps/base/{kimai,wordpress}/database.yaml`

**Offen:**
- [ ] Passwörter in den jeweiligen `secret.sops.yaml` setzen (CNPG erwartet `kubernetes.io/basic-auth`
      mit `username`/`password`; App-Env muss dasselbe Passwort referenzieren).
- [ ] HA: `instances: 1 → 3` (CNPG) bzw. `replicas: 1 → 3` (MariaDB Galera) für Produktion.
- [ ] `storageClassName` verifizieren.
- [ ] CNPG-Backup (barmanObjectStore) konfigurieren → siehe Abschnitt 11.

**Beispiel** — CNPG-Cluster mit Backup:
```yaml
spec:
  instances: 3
  backup:
    barmanObjectStore:
      destinationPath: s3://cnpg-backups/forgejo
      endpointURL: https://s3.DEINE-DOMAIN.tld
      s3Credentials: { accessKeyId: {name: cnpg-s3, key: ACCESS}, secretAccessKey: {name: cnpg-s3, key: SECRET} }
```

---

## 8. Cache (Valkey)

**Dateien:** jedes `apps/base/*/cache.yaml` (eigenständige Valkey-Instanz pro App)

> Der `hyperspike/valkey-operator` wurde entfernt (Upstream-Chart-Repo mit
> abgelaufenem TLS-Zertifikat). Jede App betreibt jetzt ein eigenes, isoliertes
> Valkey-StatefulSet + Service unter demselben DNS-Namen `<app>-valkey:6379`.

> **Ausnahme mastodon:** das offizielle Chart erzwingt Redis-Auth. Die
> mastodon-Valkey läuft daher mit `requirepass` aus dem Secret `mastodon-redis`,
> auf das auch `values.redis.existingSecret` zeigt. Alle anderen Apps laufen
> (vorerst) passwortlos.

**Offen:**
- [ ] HA: `replicas: 1 → 3` + Sentinel/Cluster-Topologie für Apps mit harten Cache-Anforderungen.
- [ ] Pro App prüfen, ob Valkey-Verbindung (Host/Port/DB-Index) in den App-Env/Values stimmt.
- [ ] `storageClassName` (`ceph-rbd`) und Größe pro App final setzen.
- [ ] `mastodon-redis`-Passwort setzen + verschlüsseln (Valkey `requirepass` ↔ App müssen identisch sein).

**Beispiel** (`apps/base/forgejo/cache.yaml`) — eine kleine, isolierte Instanz pro App:
```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: forgejo-valkey, namespace: forgejo }
spec: { serviceName: forgejo-valkey, replicas: 1, ... } # + Service forgejo-valkey:6379
```

---

## 9. Identity / OIDC (Authentik)

**Dateien:** `infrastructure/base/authentik/*`, `infrastructure/base/authentik/blueprints/*`

**Offen:**
- [ ] `authentik-secret` füllen (SECRET_KEY, Bootstrap-Credentials) + verschlüsseln.
- [ ] CNPG-Owner-Secret für Authentik-DB angleichen (siehe Hinweis in `postgres.yaml`).
- [ ] Pro App `client_id`/`client_secret` in Blueprint **und** App-Secret identisch setzen.
- [ ] redirect_uris an reale Domain anpassen; Flows/Scopes prüfen.
- [ ] Weitere Apps (kimai web-login, roundcube, mastodon, wordpress) nach AGENTS.md-Checkliste onboarden.

**Beispiel** — Blueprint-Provider (`infrastructure/base/authentik/blueprints/forgejo-oauth.yaml`):
```yaml
- model: authentik_providers_oauth2.oauth2provider
  attrs:
    client_id: forgejo-client-id
    client_secret: <gleich wie in forgejo-secret>
    redirect_uris: [{ matching_mode: strict, url: https://git.DEINE-DOMAIN.tld/user/oauth2/authentik/callback }]
```

---

## 10. Observability & Alerting

**Dateien:** `infrastructure/base/monitoring/*`

**Offen:**
- [ ] Grafana-Admin-Passwort aus SOPS-Secret statt Klartext (`adminPassword`).
- [ ] **Alertmanager-Receiver** konfigurieren (aktuell `"null"`) — z.B. Matrix/Email/ntfy.
      (AGENTS.md: „Alertmanager → Notification needs to be done!")
- [ ] Retention/Storage-Size an Clustergröße anpassen.
- [ ] ServiceMonitor/PodMonitor-Scrape für CNPG, MariaDB, Valkey, NGINX, Cilium prüfen.

**Beispiel** — Alertmanager-Receiver (`infrastructure/base/monitoring/values.yaml`):
```yaml
alertmanager:
  config:
    route: { receiver: ntfy }
    receivers:
      - name: ntfy
        webhook_configs: [{ url: https://ntfy.DEINE-DOMAIN.tld/alerts }]
```

---

## 11. Kubernetes MCP Server

**Dateien:** `infrastructure/base/kubernetes-mcp/*`

**Offen:**
- [ ] `htpasswd`-Wert in `secret.sops.yaml` generieren + verschlüsseln:
      `htpasswd -nb mcp <starkes-passwort>` → in `stringData.htpasswd` eintragen.
- [ ] Claude Code konfigurieren: `Authorization: Basic base64(mcp:<passwort>)` als Header setzen.

---

## 12. Backup & Disaster Recovery

**Verdrahtet (Blaupause):** DB-Backups sind in den Manifesten aktiv — täglich 02:00 nach Ceph S3,
30 Tage Retention.
- **CNPG** (roundcube, paperless, forgejo, mastodon, mailman, authentik): `backup.barmanObjectStore` im
  jeweiligen `database.yaml` (bzw. `postgres.yaml`) + `ScheduledBackup` in `backup.yaml`.
  Continuous WAL + base → PITR.
- **MariaDB** (kimai, wordpress): `Backup` CR in `apps/base/<app>/backup.yaml` (logischer Dump).
- **S3-Creds**: `<app>-backup-s3` Secret in jeder `secret.sops.yaml`.
- **Keine DB**: Icecast ist zustandsarm; Backup betrifft nur die GitOps-Konfiguration und externe
  Stream-Quellen/Clients.

**Dateien:** `apps/base/*/backup.yaml`, `apps/base/*/database.yaml`, `infrastructure/base/authentik/{postgres,backup}.yaml`,
`apps/base/*/secret.sops.yaml`, `infrastructure/overlays/main/` (DR-Overlay, anzulegen)

**Offen:**
- [ ] S3-Buckets anlegen (OBC oder direkt RGW): `cnpg-<app>`, `mariadb-<app>`. Namen in
      `destinationPath`/`bucket` müssen existieren.
- [ ] `<app>-backup-s3` Secrets mit echten Ceph-RGW-Keys füllen + verschlüsseln.
- [ ] `endpointURL`/`endpoint` (`s3.jit.services`) auf reale RGW-URL setzen.
- [ ] CNPG ≥1.26: `barmanObjectStore` in-tree ist deprecated → auf **barman-cloud Plugin** migrieren.
- [ ] MariaDB **PITR**: für punktgenaues Restore `PhysicalBackup` CRD + Binlog statt logischem Dump.
- [ ] DR-Overlay `infrastructure/overlays/disaster-recovery/` mit `bootstrap.recovery` anlegen.
- [ ] PVC-Daten (paperless media/consume, forgejo repos, wordpress wp-content, mastodon-uploads via S3)
      Backup-Strategie (Ceph-Snapshots / Velero) — DB-Backup deckt nur die Datenbank.
- [ ] Restore-Runbook in `docs/runbooks/` schreiben + testen.

**Beispiel** — CNPG continuous backup (`apps/base/forgejo/database.yaml` + `backup.yaml`):
```yaml
# Cluster.spec:
backup:
  retentionPolicy: "30d"
  barmanObjectStore:
    destinationPath: s3://cnpg-forgejo/
    endpointURL: https://s3.DEINE-DOMAIN.tld
    s3Credentials:
      accessKeyId: { name: forgejo-backup-s3, key: ACCESS_KEY_ID }
      secretAccessKey: { name: forgejo-backup-s3, key: SECRET_ACCESS_KEY }
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata: { name: forgejo-pg, namespace: forgejo }
spec: { schedule: "0 0 2 * * *", cluster: { name: forgejo-pg } }
```

---

## 13. CI & Renovate

**Dateien:** `.forgejo/workflows/ci.yaml`, `renovate.json`, `apps/base/renovate/*`

**Offen:**
- [ ] Forgejo-Actions-Runner registrieren (Token via `get_runner_registration_token`).
- [ ] Entscheiden: GitHub *leading* (AGENTS.md) vs. Forgejo (Repo-Host) — Workflows entsprechend
      spiegeln. Aktuell `.forgejo/workflows/`.
- [ ] Renovate-Token (Forgejo) in `apps/base/renovate/secret.sops.yaml` setzen.
- [ ] `endpoint`/`gitAuthor` in `apps/base/renovate/config.js` anpassen.
- [ ] `# renovate:`-Kommentare an Helm-Versionen prüfen (datasource helm/docker).

**Beispiel** — Renovate gegen Forgejo (`apps/base/renovate/config.js`):
```js
module.exports = { platform: 'gitea', endpoint: 'https://git.DEINE-DOMAIN.tld/api/v1', autodiscover: true };
```

---

## 14. Mail (extern)

**Dateien:** `apps/base/roundcube/workload.yaml`, `apps/base/mastodon/{values,secret.sops}.yaml`,
`apps/base/mailman/{workload,secret.sops}.yaml`

**Offen:**
- [ ] Externen IMAP/SMTP-Host in roundcube setzen (`ROUNDCUBEMAIL_DEFAULT_HOST`/`SMTP_SERVER`).
- [ ] SMTP-Credentials für Mastodon (`mastodon-smtp`) + Paperless/Authentik (falls Mailversand).
- [ ] Mailman: externes MTA/Gateway so konfigurieren, dass Listendomains an
      `mailman-core.mailman.svc.cluster.local:8024` (LMTP) geroutet werden; ausgehend nutzt Mailman
      `SMTP_HOST`/`SMTP_PORT` aus `workload.yaml`.
- [ ] Mailman: `MAILMAN_ADMIN_EMAIL`, `SMTP_HOST_USER`, `HYPERKITTY_API_KEY`, `SECRET_KEY` und
      REST-Passwort in `apps/base/mailman/secret.sops.yaml` setzen + verschlüsseln.
- [ ] SPF/DKIM/DMARC beim externen Mailprovider (außerhalb des Clusters).

**Beispiel** (`apps/base/roundcube/workload.yaml`):
```yaml
- name: ROUNDCUBEMAIL_DEFAULT_HOST
  value: "ssl://imap.DEINE-DOMAIN.tld"
- name: ROUNDCUBEMAIL_SMTP_SERVER
  value: "tls://smtp.DEINE-DOMAIN.tld"
```

---

## 15. Pro-App-TODOs

Jede App liegt unter `apps/base/<app>/` (Basis) + `apps/overlays/main/<app>/` (Cluster-Patch).

| App | Pfad (Basis) | Offene App-spezifische Schritte |
|-----|--------------|----------------------------------|
| **kimai** | `apps/base/kimai/` | Secret füllen; `serverVersion` der MariaDB im `DATABASE_URL` angleichen; OIDC aktivieren (Web-Login). |
| **roundcube** | `apps/base/roundcube/` | Legacy-Domains `roundcube.savar.de`, `mail.steinba.ch`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de` und `webmail.daec-berlin.de` sind im Overlay als Übergangs-Ingress ergänzt; TLS endet dort am Legacy-Traefik. Externen IMAP/SMTP setzen; `managesieve`-Backend prüfen; Session-Cache auf Valkey umstellen (config). |
| **collabora** | `apps/base/collabora/` | `aliasgroups`-Regex auf reale WOPI-Hosts; Admin-Passwort; WOPI-Client (z.B. Nextcloud) anbinden. |
| **paperless-ngx** | `apps/base/paperless-ngx/` | Externe Domain `paperless.savar.de` ist im Overlay gesetzt; TLS endet während der Migration am Legacy-Traefik. Admin + SECRET_KEY; OIDC-JSON `server_url`/`secret`; CephFS-RWX für media/consume bestätigen. |
| **forgejo** | `apps/base/forgejo/` | Admin-Secret; SSH-Service exponieren (LB/NodePort); OIDC-Provider in Forgejo anlegen; LFS→S3 optional. |
| **renovate** | `apps/base/renovate/` | Forgejo-Token; `autodiscover` vs. feste Repo-Liste; Schedule abstimmen. |
| **wordpress-1/2/3** | `apps/base/wordpress/` + `apps/overlays/main/wordpress-{1,2,3}/` | Pro Instanz Secret + Host (in Overlay gepatcht); „Redis Object Cache"-Plugin installieren; `mariadb.enabled:false` + externalDatabase final schalten. |
| **mastodon** | `apps/base/mastodon/` | Chart migriert auf offizielles `mastodon/helm-charts` (0.5.1). Secret `mastodon-secret` (`secret-key-base`/VAPID/`are-*` Active-Record-Encryption-Keys) generieren; `mastodon-redis`-Passwort setzen (Valkey `requirepass`); S3 (OBC) verdrahten; SMTP; Streaming-WebSocket testen; ggf. Elasticsearch. ArgoCD: `mastodon.hooks` (dbPrepare/dbMigrate Helm-Hooks) für GitOps-Sync prüfen. |
| **gatus** | `apps/base/gatus/` | `gatus-oidc`-Secret füllen (== Blueprint-`client_secret`); `issuer-url`/`redirect-url`/`client-id` auf reale Domain; echte `endpoints` statt Samples eintragen. |
| **kite** | `apps/base/kite/` | `kite-secrets` füllen (`JWT_SECRET`/`KITE_ENCRYPT_KEY` via `openssl rand -hex 32`, `OAUTH_CLIENT_SECRET` == Blueprint); `issuer`/`clientId` setzen; RBAC-Rollen-Mapping für OIDC-User; PVC-StorageClass prüfen. |
| **mailman** | `apps/base/mailman/` | Secrets füllen (`HYPERKITTY_API_KEY`, `SECRET_KEY`, REST-Passwort, `MAILMAN_ADMIN_EMAIL`, `SMTP_HOST_USER`); externes MTA auf LMTP-Service routen; CNPG-Bucket `cnpg-mailman`/S3-Creds anlegen; PVC- und DB-Größen prüfen; erste Admin-Initialisierung testen. |
| **icecast** | `apps/base/icecast/` | Source/Admin/Relay-Passwörter setzen; Source-Clients auf HTTPS-URL und Source-Passwort umstellen; Listener-Limit und Ingress-Timeouts nach Stream-Profil prüfen. |
| **phpmyadmin** | `apps/base/phpmyadmin/` | Legacy-Domains `phpmyadmin.savar.de`/`phpmyadmin.jit-creatives.de` sind im Overlay ergänzt; TLS endet dort am Legacy-Traefik. Zugriff absichern (Authentik Forward-Auth oder IP-Allowlist); nur dedizierte DB-User statt Root verwenden; Default-DB-Host `kimai-mariadb.kimai.svc.cluster.local` prüfen; weitere Ziele als FQDN eintragen. |

**Beispiel** — neue App hinzufügen (Kurzform, Details in AGENTS.md):
```
apps/base/<app>/{kustomization,values|workload,database,cache,backup,secret.sops}.yaml
apps/overlays/main/<app>/kustomization.yaml   # -> wird von appset-apps automatisch deployed
```
```

---

## Vor dem ersten `argocd app sync` lokal prüfen

```bash
just build   # kustomize build --enable-helm über alle overlays
just test    # + kubeconform Schema-Validierung
just lint    # yamllint
just secrets-check   # keine Klartext-*.sops.yaml
```
