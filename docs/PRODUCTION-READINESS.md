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
9. [Identity/OIDC](#9-identity--oidc-external-keycloak) → 10. [Observability](#10-observability--alerting) →
11. [Backup/DR](#11-backup--disaster-recovery) → 12. [CI & Renovate](#12-ci--renovate) →
13. [Mail](#13-mail-extern) → 14. [Pro-App-TODOs](#14-pro-app-todos).

---

## 1. Bootstrap & Talos

**Dateien:** (Talos-Config liegt außerhalb dieses Repos — `talosctl`/`talconfig`),
`infrastructure/base/cilium/values.yaml`

**Offen:**
- [ ] Talos-Cluster provisionieren (control-plane + worker), `kubeconfig` exportieren.
- [x] Nix Dev-Shell bereitstellen (`flake.nix`) mit `kubectl, kustomize, helm, sops,
      age, kubeconform, just, argocd`.
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
      ggf. verfeinern: cilium → cert-manager/CRDs → operatoren → monitoring → apps).

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
- [ ] CI-Gate aktiv halten (`just secrets-check`) — warnt bei Blueprint-Platzhaltern
      und blockiert echte unverschluesselte Secret-Dateien.

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
- [x] **Globaler NGINX-Default**: `client-max-body-size: 10m` (Fallback, App-Ingresses überschreiben
      bei Bedarf höher) in `infrastructure/base/ingress-nginx/values.yaml`. HSTS bewusst noch nicht
      global aktiviert, solange TLS teils extern am Legacy-Traefik terminiert (HTTP-only-Ingresses,
      s. o.) — erst nach Cluster-direktem-TLS-Cutover nachziehen.
- [x] **Echte Client-IP**: `set-real-ip-from: 192.168.2.0/24` + `real-ip-header: X-Forwarded-For`
      + `real-ip-recursive: True`. Vorher loggte nginx für jeden Request eine Proxy-/Node-Adresse
      (`.15`-Traefik davor + `externalTrafficPolicy: Cluster` SNAT'ed) — Access-Logs, Rate-Limits
      und CrowdSec sahen praktisch nur eine IP.
      **Nach dem Rollout verifizieren:** externe Test-Anfrage absetzen und im nginx-Access-Log
      prüfen, dass die echte Client-IP erscheint. Falls nicht, sieht nginx vermutlich eine
      Pod-Adresse als Peer → Pod-CIDR zu `set-real-ip-from` ergänzen.
      *Nicht* mit erledigt: die WordPress-Apache-Logs — Apache loggt weiterhin die nginx-Pod-IP,
      dafür bräuchte es `mod_remoteip` im WordPress-Image.
- [ ] LoadBalancer-IP-Quelle wählen: Cilium LB-IPAM **oder** MetalLB-Pool → Ingress-Service
      bekommt externe IP.
- [ ] DNS-Records (A/AAAA bzw. CNAME) für alle Hosts aus `cluster-config.yaml` auf die LB-IP.
- [ ] Wildcard-DNS `*.DEINE-DOMAIN.tld` optional für weniger Pflege.
- [ ] Direkten WAN-Cutover auf `192.168.2.246` und Abschaltung von
      `192.168.2.15` nach `docs/runbooks/docker15-retirement.md` vorbereiten.
      Harte Gates sind vollständiges Cluster-TLS via DNS-01, erhaltene und
      spoof-resistente Client-IP, CrowdSec-Enforcement sowie die Ablösung von
      Postfix und Legacy-Datenbanken auf `.15`. `192.168.23.20` bleibt reiner
      DR-Edge für ein mögliches Routing über Potsdam.

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
- [ ] Vor CephFS-Aktivierung Cross-Node-RWX und CSI-Recovery nach einem
      kontrollierten Node-Reboot testen; MDS-Session und reales Datei-I/O
      explizit verifizieren (`docs/learnings/external-cephfs-client-stall-recovery.md`).
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

DNS-01 nutzt explizite, zonenbegrenzte Solver. `jit.services` läuft über den
ClouDNS-Webhook. RFC2136/TSIG gegen `dns01.jit-creatives.de` bedient `savar.de`,
`jit-creatives.de`, `jitcreatives.de`, `jitmail.de`, `gemeinsam-fuer-halbe.de`,
`jugendbeauftragter-halbe.de`, `aios.tools`, `jit.cloud` und `daec-berlin.de`.
`binaergewitter.de` nutzt vorübergehend den aus Traefik übernommenen globalen
Cloudflare-API-Key. Die Secrets liegen SOPS-verschlüsselt im cert-manager-Base.

Production und Staging besitzen dieselbe Solvermatrix. Drei Staging-Certificates
prüfen ClouDNS, RFC2136 und Cloudflare vor dem produktiven Ingress-TLS-Rollout.
`horads.de` und `steinba.ch` nutzen zusätzlich einen ausschließlich auf diese
beiden Zonen selektierten HTTP-01-Solver. Die Challenge wird wegen der strikten
Host-Eindeutigkeit von nginx-inc in-place im vorhandenen Ingress ergänzt. Ein
unselektierter HTTP-01-Fallback existiert bewusst nicht mehr.

**Offen:**
- [ ] Alle drei DNS-01-Staging-Certificates sowie die Staging-Zertifikate für
      `stream.horads.de`, `mail.steinba.ch`, `cloud.steinba.ch` und den
      `imcor.de`/`jonaks.com`-SAN-Satz als `Ready=True` prüfen und den tatsächlich
      gewählten Solver bestätigen.
- [ ] Den globalen Cloudflare-Key durch einen auf `binaergewitter.de` beschränkten
      API-Token mit `Zone:Read` und `DNS:Edit` ersetzen.
- [x] Sechs `_acme-challenge`-CNAMEs für `imcor.de` und `jonaks.com` bei United
      Domains angelegt und autoritativ sowie über mehrere öffentliche Resolver
      verifiziert. TXT-Create, Auflösung über die ursprünglichen Namen und Cleanup
      waren für alle sechs Delegationen erfolgreich. Der negative Cache für
      `db.imcor.de` auf `1.1.1.1` muss vor dem Staging-Rollout ablaufen.
- [ ] `_acme-challenge.cloud.naturkindergarten-moehringen.de` beim Provider
      anlegen; erst danach TLS für diesen Namen aktivieren.
- [ ] Nach erfolgreichem TLS-Rollout die temporären Staging-Certificates entfernen.

**Beispiel** (`infrastructure/base/cert-manager/cluster-issuer.sops.yaml`):
```yaml
spec:
  acme:
    email: admin@jit.services
    solvers:
      - dns01: { webhook: { groupName: acme.jit.services, solverName: cloudns } }
        selector: { dnsZones: [jit.services] }
```

---

## 7. Datenbanken

**Postgres (CNPG):** `infrastructure/base/cnpg/`, `apps/base/{roundcube,paperless-ngx,forgejo,mastodon,mailman}/database.yaml`; legacy Authentik manifests remain in-tree but are excluded from ArgoCD
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

## 9. Identity / OIDC (External Keycloak)

**Dateien:** App-spezifische `values.yaml` und `secret.sops.yaml`; externer Keycloak auf `auth.savar.de`, Realm `bgt`

**Offen:**
- [ ] Keycloak auf Zielversion aktualisieren und Custom SPI passend bauen.
- [ ] Binärgewitter-Theme im Realm `bgt` aktivieren.
- [ ] Pro App Keycloak-Client mit korrekter Redirect-URI anlegen.
- [ ] Pro App `client_id`/`client_secret` im SOPS-Secret identisch zum Keycloak-Client setzen.
- [ ] OIDC pro App erst nach Client-/Secret-Abgleich aktivieren und Login testen.

**Issuer:**
```text
https://auth.savar.de/realms/bgt
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
- [ ] Alerts fuer CephFS-CSI-Mount-/Sessionfehler und das Alter des letzten
      erfolgreichen Backups einrichten; ein vorhandener Zeitplan reicht nicht.

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
- [x] RBAC read-only halten: keine Write-Verben, kein Secret-Zugriff. CI prüft das über
      `just guardrails`.

---

## 12. Backup & Disaster Recovery

**Verdrahtet (Blaupause):** DB-Backups sind in den Manifesten aktiv — täglich 02:00 nach Ceph S3,
30 Tage Retention.
- **CNPG** (roundcube, paperless, forgejo, mastodon, mailman): `backup.barmanObjectStore` im
  jeweiligen `database.yaml` (bzw. `postgres.yaml`) + `ScheduledBackup` in `backup.yaml`.
  Continuous WAL + base → PITR.
- **MariaDB** (kimai, wordpress): `Backup` CR in `apps/base/<app>/backup.yaml` (logischer Dump).
- **S3-Creds**: `<app>-backup-s3` Secret in jeder `secret.sops.yaml`.
- **Keine DB**: Icecast ist zustandsarm; Backup betrifft nur die GitOps-Konfiguration und externe
  Stream-Quellen/Clients.

**Dateien:** `apps/base/*/backup.yaml`, `apps/base/*/database.yaml`,
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

**Dateien:** `.github/workflows/ci.yml`, `renovate.json`,
`apps/base/renovate/*`, `scripts/ci/guardrails.sh`

**Offen:**
- [ ] GitHub-Token in `apps/base/renovate/secret.sops.yaml` setzen.
- [ ] `gitAuthor` in `apps/base/renovate/config.js` anpassen.
- [x] Renovate läuft gegen GitHub (`keller-IO/kubernetes-gitops`) und ignoriert
      `.forgejo/**`.
- [x] `# renovate:`-Kommentare an Helm-, Docker- und Workflow-Versionen werden
      durch `customManagers` abgedeckt.
- [x] CI führt `scripts/ci/guardrails.sh` aus; lokal bündelt `just validate`
      Guardrails, Lint, Secret-Check, Kustomize-Build und kubeconform.
- [x] Guardrails blockieren `:latest`, `imagePullPolicy: Always`, verdächtige
      Klartext-Secrets, mutierende Cluster-Kommandos in Automation und Write-RBAC
      für den Kubernetes MCP Server.

**Beispiel** — Renovate gegen GitHub (`apps/base/renovate/config.js`):
```js
module.exports = { platform: 'github', repositories: ['keller-IO/kubernetes-gitops'] };
```

---

## 14. Mail (extern)

**Dateien:** `apps/base/roundcube/workload.yaml`, `apps/base/mastodon/{values,secret.sops}.yaml`,
`apps/base/mailman/{workload,secret.sops}.yaml`

**Offen:**
- [ ] Externen IMAP/SMTP-Host in roundcube setzen (`ROUNDCUBEMAIL_DEFAULT_HOST`/`SMTP_SERVER`).
- [ ] SMTP-Credentials für Mastodon (`mastodon-smtp`) + Paperless (falls Mailversand).
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
| **roundcube** | `apps/base/roundcube/` | Legacy-Domains `roundcube.savar.de`, `mail.steinba.ch`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de` und `webmail.daec-berlin.de` sind im Overlay als Übergangs-Ingress ergänzt; TLS endet dort am Legacy-Traefik. PostgreSQL-Schemafehler der historischen pgloader-Migration am 27.07. repariert (`postgres-schema-repair-20260727.sql`). Externen IMAP/SMTP setzen; `managesieve`-Backend prüfen; Session-Cache auf Valkey umstellen (config). |
| **collabora** | `apps/base/collabora/` | `aliasgroups`-Regex auf reale WOPI-Hosts; Admin-Passwort; WOPI-Client (z.B. Nextcloud) anbinden. |
| **eurooffice** | `apps/base/eurooffice/` | JWT-Secret (`jwt-secret`, bereits generiert/verschlüsselt) in der Nextcloud-Connector-App spiegeln (`occ config:app:set eurooffice ...` auf nc01/nc02-dev, URL `https://eurooffice.jit.services`); All-in-One-Image (interne PG/RabbitMQ/Redis) — bei >1 Nextcloud auf offizielles Kubernetes-Docs-Chart + CNPG umstellen (braucht CephFS-RWX); Erststart dauert (Font-Cache), Healthcheck `/healthcheck`. |
| **paperless-ngx** | `apps/base/paperless-ngx/` | Externe Domain `paperless.savar.de` ist im Overlay gesetzt; TLS endet während der Migration am Legacy-Traefik. Admin + SECRET_KEY; OIDC-JSON `server_url`/`secret`; CephFS-RWX für media/consume bestätigen. |
| **forgejo** | `apps/base/forgejo/` | Admin-Secret; SSH-Service exponieren (LB/NodePort); OIDC-Provider in Forgejo anlegen; LFS→S3 optional. |
| **renovate** | `apps/base/renovate/` | Forgejo-Token; `autodiscover` vs. feste Repo-Liste; Schedule abstimmen. |
| **wordpress-1/2/3** | `apps/base/wordpress/` + `apps/overlays/main/wordpress-{1,2,3}/` | Pro Instanz Secret + Host (in Overlay gepatcht); „Redis Object Cache"-Plugin installieren; `mariadb.enabled:false` + externalDatabase final schalten. |
| **mastodon** | `apps/base/mastodon/` | Chart migriert auf offizielles `mastodon/helm-charts` (0.5.1). Secret `mastodon-secret` (`secret-key-base`/VAPID/`are-*` Active-Record-Encryption-Keys) generieren; `mastodon-redis`-Passwort setzen (Valkey `requirepass`); S3 (OBC) verdrahten; SMTP; Streaming-WebSocket testen; ggf. Elasticsearch. ArgoCD: `mastodon.hooks` (dbPrepare/dbMigrate Helm-Hooks) für GitOps-Sync prüfen. |
| **gatus** | `apps/base/gatus/` | `gatus-oidc`-Secret mit Keycloak-Client-Secret füllen; `issuer-url`/`redirect-url`/`client-id` auf reale Domain. Alle kanonischen Web-App-Endpunkte sind eingetragen; Paperless wird über `paperless.savar.de` geprüft und folgt dem Login-Redirect bis HTTP 200. Gewünschte Legacy- und Alias-Domains bei Bedarf als eigene Routengruppe ergänzen. |
| **kite** | `apps/base/kite/` | `kite-secrets` füllen (`JWT_SECRET`/`KITE_ENCRYPT_KEY` via `openssl rand -hex 32`, `OAUTH_CLIENT_SECRET` == Keycloak-Client-Secret); `issuer`/`clientId` setzen; RBAC-Rollen-Mapping für OIDC-User; PVC-StorageClass prüfen. |
| **mailman** | `apps/base/mailman/` | Secrets füllen (`HYPERKITTY_API_KEY`, `SECRET_KEY`, REST-Passwort, `MAILMAN_ADMIN_EMAIL`, `SMTP_HOST_USER`); externes MTA auf LMTP-Service routen; CNPG-Bucket `cnpg-mailman`/S3-Creds anlegen; PVC- und DB-Größen prüfen; erste Admin-Initialisierung testen. |
| **icecast** | `apps/base/icecast/` | Source/Admin/Relay-Passwörter setzen; Source-Clients auf HTTPS-URL und Source-Passwort umstellen; Listener-Limit nach Stream-Profil prüfen (Ingress-Timeouts/Buffering für Live-Streaming sind gesetzt: `proxy-buffering off`, 3600s Read/Send-Timeout). |
| **phpmyadmin** | `apps/base/phpmyadmin/` | Legacy-Domains `phpmyadmin.savar.de`/`phpmyadmin.jit-creatives.de` sind im Overlay ergänzt; TLS endet dort am Legacy-Traefik. Zugriff absichern (IP-Allowlist oder separater Auth-Proxy); nur dedizierte DB-User statt Root verwenden; Default-DB-Host `kimai-mariadb.kimai.svc.cluster.local` prüfen; weitere Ziele als FQDN eintragen. |
| **nextcloud-yealink-phonebook** | `apps/base/nextcloud-yealink-phonebook/` | Liest das Nextcloud-Adressbuch alle 15 Minuten per CardDAV und stellt tokenisiert Remote- sowie T46S-Local-Directory-XML bereit. Die OEM-Firmware `66.85.193.13` blockiert Remote Phone Book und verwirft `local_contact.data.url`; deshalb wurden 17 Kontakte einmalig als lokales Telefonbuch importiert und auf dem Display unter `Kontakte > Alle Kontakte > Eingeben` validiert. Automatische Telefonaktualisierung bleibt offen und erfordert Kontrolle des PnP/DHCP-Provisionierungsservers oder einen getesteten Web-Upload-Client. Details: `docs/learnings/yealink-t46s-oem-phonebook.md`. |
| **cloud-dev proxy** | `apps/base/legacy-proxy/` | `cloud-dev.savar.de` bleibt auf `nc01-dev` (`192.168.2.220`), läuft aber über Traefik TLS -> Cluster-LB `.246` -> nginx-inc. Hauptdienst wird zu HTTPS/443 re-encryptet; `/push/` geht per WebSocket und Strip-Prefix an notify_push/7867. EndpointSlices nach dem ArgoCD-Sync einmalig manuell anwenden; Nextcloud vertraut dem Pod-CIDR `10.244.0.0/16`. `nc02-dev` (`.221`) erst nach Erreichbarkeits- und Release-Prüfung wieder aufnehmen. |

**Beispiel** — neue App hinzufügen (Kurzform, Details in AGENTS.md):
```
apps/base/<app>/{kustomization,values|workload,database,cache,backup,secret.sops}.yaml
apps/overlays/main/<app>/kustomization.yaml   # -> wird von appset-apps automatisch deployed
```
```

---

## 16. CrowdSec (Intrusion Detection)

**Dateien:** `infrastructure/base/crowdsec/*`

**Status: Detection-only.** LAPI + Agent-DaemonSet laufen und erzeugen Alerts/Decisions
(`cscli alerts list`, `cscli decisions list`), aber es wird noch **nichts aktiv geblockt** —
es ist bewusst noch kein Bouncer verdrahtet.

**Warum kein Bouncer im ersten Wurf:** Es gibt kein offizielles CrowdSec-Produkt, das
Kubernetes-NetworkPolicies durchsetzt. Die real existierenden Optionen:
- `cs-firewall-bouncer` (offiziell, gepflegt) — braucht ein privilegiertes DaemonSet
  (`NET_ADMIN` + `hostNetwork`) auf jedem Talos-Node, das nftables direkt manipuliert.
- `cs-netpol-bouncer` (Community, genau das NetworkPolicy-Konzept) — 0 GitHub-Stars,
  wirkt unmaintained, nicht für produktives Enforcement empfohlen.
- `cs-wordpress-bouncer` (offiziell) — blockt direkt in WordPress/PHP, passt zum
  konkreten Vorfall (`docs/learnings/` — wordpress-2 Webshell-Kompromittierung).
- Detection-only (aktueller Stand) — erst beobachten, dann in einem Folge-PR
  einen Bouncer scharfschalten, sobald die Trefferquote geprüft ist.

**Architektur:**
- **LAPI**: eigene Postgres-Instanz via CNPG (`postgres.yaml`, `crowdsec-pg`) statt der
  eingebauten SQLite — konsistent mit jeder anderen zustandsbehafteten Komponente hier.
- **Agent**: DaemonSet, liest Pod-Logs via `agent.acquisition` (namespace/podName/program).
  Aktuell verdrahtet: `ingress-nginx` (deckt über den gemeinsamen nginx-inc-Ingress
  praktisch jede App ab) + `wordpress-1/2/3` (Apache-Logs direkt, ergänzend).
- **Kein Console-Enrollment**: läuft rein lokal, keine Daten gehen an crowdsec.net,
  kein Community-Blocklist-Sharing.
- `container_runtime: containerd` gesetzt (Talos-Nodes, Chart-Default ist `docker`).

### ⚠️ Blocker: echte Client-IP fehlt in den Logs

CrowdSec ist nur so gut wie die IP-Adresse in der Logzeile — und die stimmt aktuell nicht.
Der Weg ist Router → `.15`-Traefik → LB `192.168.2.246` → nginx-inc. Dabei gilt:
- Der Ingress-Service läuft mit `externalTrafficPolicy: Cluster`, SNAT'ed also die
  Source-IP (bewusst so, siehe Kommentar in `infrastructure/base/ingress-nginx/values.yaml`
  — `Local` verursachte am 22.07. einen Ausfall).
- In `config.entries` war **kein** `set-real-ip-from` / `real-ip-header` gesetzt.

**Fix liegt als eigener PR vor** (`fix/ingress-real-client-ip`): setzt
`set-real-ip-from: 192.168.2.0/24` + `real-ip-header: X-Forwarded-For` +
`real-ip-recursive: True`. Dieser PR hier bringt erst Nutzen, wenn jener gemergt
**und** die Post-Deploy-Prüfung unten bestanden ist.

Folge: nginx loggt für *jeden* Request eine Proxy- bzw. Node-Adresse. CrowdSec sieht
damit praktisch nur eine einzige IP, Alerts sind wertlos — und ein später aktivierter
Bouncer würde genau diese Proxy-IP bannen und **die komplette Site abschalten**.
Dasselbe gilt für die Apache-Logs der WordPress-Pods (die sehen die nginx-Pod-IP).

**Zu tun, bevor CrowdSec Nutzen bringt (und zwingend vor jedem Bouncer):**
- [ ] Prüfen, ob der `.15`-Traefik `X-Forwarded-For` sauber setzt (Default: ja).
- [ ] In `infrastructure/base/ingress-nginx/values.yaml` unter `config.entries` ergänzen:
      ```yaml
      real-ip-header: "X-Forwarded-For"
      real-ip-recursive: "True"
      set-real-ip-from: "<Traefik-IP + Node-/Pod-CIDR>" # z.B. 192.168.2.15, 192.168.2.0/24
      ```
      Wichtig: wegen des SNAT ist der TCP-Peer, den nginx sieht, **nicht** `192.168.2.15`,
      sondern eine Node-Adresse — `set-real-ip-from` muss daher auch das Node-/Pod-CIDR
      abdecken, sonst greift die Auswertung nicht. Exakte CIDRs vor dem Setzen verifizieren.
- [ ] Danach in einem nginx-Access-Log gegenprüfen, dass eine externe Test-Anfrage mit
      der echten Client-IP auftaucht.

**Offen (Rest):**
- [ ] `secret.sops.yaml` ist noch **unverschlüsselt** (Platzhalter, kein sops/age in der
      Umgebung verfügbar, die diesen PR erzeugt hat) — echte Werte eintragen und
      `just encrypt infrastructure/base/crowdsec/secret.sops.yaml`.
- [ ] Garage-S3-Bucket `cnpg-crowdsec` anlegen, `crowdsec-backup-s3`-Credentials setzen.
- [ ] Nach ein paar Tagen Laufzeit `cscli alerts list` / `cscli metrics` prüfen —
      False-Positives? Fehlende Collections für weitere Apps (forgejo, roundcube, ...)?
- [ ] Enforcement-Entscheidung treffen (siehe oben) und in einem Folge-PR umsetzen.
- [ ] Optional: CrowdSec Console/Community-Blocklist aktivieren, falls das
      Datenteilen mit crowdsec.net gewünscht ist (aktuell bewusst deaktiviert).
- [ ] Sync-Reihenfolge beobachten: der CNPG-Operator (`infrastructure/base/cnpg`) und der
      `Cluster`-CR hier liegen beide auf sync-wave `-5`. Beim Erst-Bootstrap kann der CR
      vor der CRD landen; ArgoCD retried, konvergiert also, meldet aber kurzzeitig Fehler.

---

## 17. NetBird (Cluster-Zugriff)

**Dateien:** `infrastructure/base/netbird/*`

Externer NetBird-Server **`netbird.jit.services`**. Diese Komponente liefert **nur** den
kube-API-Zugriff — die Nodes sind bereits eigenständig NetBird-Peers (Gruppe `talos`),
ein Agent-DaemonSet ist deshalb bewusst nicht Teil davon.

- **Operator** (Helm `netbird-operator` 0.8.0, `oci://ghcr.io/netbirdio/helm-charts`).
- **ClusterProxy** — Proxy-Peer, erreichbar unter
  `keller-main.netbird-kubeapi-proxy.netbird.selfhosted`. Er impersoniert den
  NetBird-Nutzer gegenüber der API; die NetBird-Gruppennamen kommen als K8s-Groups an.

**In NetBird bereits angelegt** (nicht in Git — siehe unten warum):

| Objekt | Inhalt |
|---|---|
| Gruppe `k8s_admin` | Nutzergruppe, bestand schon |
| Gruppe `k8s_readonly` | Nutzergruppe, bestand schon |
| Gruppe `k8s_ops` | Nutzergruppe, vor dem Merge in NetBird anlegen |
| Gruppe `k8s_api_proxy` | Peer-Gruppe, nur die Proxy-Pods |
| Policy „Kubernetes API access" | `k8s_admin` + `k8s_readonly` + `k8s_ops` → `k8s_api_proxy`, tcp/443 |

**Warum keine `Group`-/`NBPolicy`-CRs**, obwohl es die CRDs gibt:
- Der Group-Controller sucht **nie nach Namen** (nur `status.GroupID`, initial leer) und
  ruft dann unbedingt `Groups.Create` — es entstünden zweite Gruppen gleichen Namens neben
  den echten. `reconcileDelete` ruft `Groups.Delete`: ein von ArgoCD geprunter CR würde die
  echte Gruppe löschen. Referenzen per `name` sind dagegen sicher — `GetGroupIDs` löst sie
  über `Groups.GetByName` auf, adoptiert also Bestehendes.
- Der NBPolicy-Controller baut Ports und Ziel-Gruppen ausschließlich aus `NBResource`-Objekten;
  `spec.ports`/`spec.destinationGroups` allein reconcilen fehlerfrei und tun **nichts**.

**Rechte:**

| NetBird-Gruppe | Kubernetes-RBAC |
|---|---|
| `k8s_admin` | `cluster-admin` |
| `k8s_readonly` | `view` + `netbird-cluster-reader` |
| `k8s_ops` | `view` + `netbird-cluster-reader` + `netbird-k8s-ops-maintainer` |

NetBird kann kein „read-only" erzwingen — Policies sind L3/L4, beide Gruppen bekommen
identisch tcp/443. Der Unterschied entsteht ausschließlich über RBAC in `rbac.yaml`.

Die ClusterRole `netbird-clusterproxy` hat bewusst **keine** `resourceNames`-Allowlist.
Der Proxy reicht alle NetBird-Gruppen als Impersonation-Groups weiter, und die API verlangt
Impersonation-Recht für jede davon. Eine Allowlist müsste deshalb auch unbeteiligte Gruppen
wie `All`, `bgt` oder `admin` enthalten und laufend nachgezogen werden. Die eigentliche
Sicherheitsgrenze ist die NetBird-Gruppenverwaltung plus die ClusterRoleBindings in
`rbac.yaml`: erst `k8s_admin`, `k8s_readonly` und `k8s_ops` bekommen Kubernetes-Rechte.

**„Alles außer Credentials"** ist eine Positivliste (RBAC kennt kein `deny`): `view` (enthält
upstream keine Secrets, aggregiert Operator-view-Rollen mit) plus `netbird-cluster-reader`
für cluster-weite Objekte. CNPG, ArgoCD, Cilium, nginx-CRDs und cert-manager-`ClusterIssuers`
sind explizit ergänzt — diese Charts liefern **keine** `aggregate-to-view`-Rolle, ohne die
Regeln sähe die Rolle weder Postgres-Cluster noch ArgoCD-Apps noch Cilium-Policies.
Bewusst draußen: `secrets`, `certificatesigningrequests`.

**`k8s_ops`** darf zusätzlich eng begrenzt mutieren, um stale/stalled Workloads zu
reparieren: Pods löschen oder evicten, Deployments/StatefulSets/ReplicaSets über die
Scale-Subresource hoch-/runterskalieren, ein bestehendes Job-Objekt löschen und Events
schreiben. Bewusst ausgeschlossen: Secrets/Credentials, `serviceaccounts/token`,
RBAC-Schreibrechte, `escalate`/`bind`/`impersonate`, `pods/exec`/`pods/attach`/
`pods/portforward`/`pods/ephemeralcontainers` — und (Audit 2026-07-29, siehe
`rbac.yaml`-Kommentar) **kein** `create`/`patch`/`update` mehr auf
Jobs/CronJobs/Deployments/StatefulSets/DaemonSets/ReplicaSets selbst und **kein**
Schreibrecht mehr auf `argoproj.io/applications`: jedes dieser Rechte kontrolliert die
PodSpec eines Workloads (Secret-Mount, `envFrom`, oder `serviceAccountName`-Hijack einer
beliebigen bestehenden ServiceAccount samt deren automatisch gemountetem Token — dafür
ist `serviceaccounts/token` nicht nötig) bzw. bei ArgoCD-Applications sogar die
Sync-Source, was ArgoCD dann mit eigenen, clusterweiten `*/* -> [*]`-Rechten anwendet.
Damit entfällt operativ: ein Backup-CronJob lässt sich über `k8s_ops` nicht mehr manuell
nachtriggern (braucht `jobs: create`), `kubectl rollout restart` funktioniert nicht mehr
(ersetzt durch `pods: delete`, gleicher Effekt ohne PodSpec-Zugriff), und ein hängender
ArgoCD-Sync lässt sich nicht mehr per `kubectl patch application` abbrechen. Letzteres
gehört ohnehin in ArgoCDs eigenes RBAC (`argocd-rbac-cm`, Aktion `sync`) statt auf
Kubernetes-Ebene — aktuell nicht nutzbar, da `argocd-rbac-cm` kein `policy.csv` hat und
ArgoCD keine SSO/OIDC-Anbindung besitzt (Folge-PR, außerhalb dieses Scopes).

**Nach dem Merge zu tun:**
- [ ] `kubectl` je Gruppe testen. Erwartung readonly: `get pods -A` geht, `get secret -A` 403.
      Kubeconfig zeigt auf `https://keller-main.netbird-kubeapi-proxy.netbird.selfhosted`.
- [ ] Erwartung ops: `delete pod`, `create pods/eviction`, `patch deployment/scale` gehen;
      `get secret -A`, `create serviceaccounts/token`, `create jobs`, `patch deployment`,
      `patch cronjob`, `patch application.argoproj.io`, `patch clusterrole`, `kubectl exec`,
      `kubectl attach` und `kubectl port-forward` bleiben 403.
- [ ] Prüfen, dass der Proxy-Peer in NetBird auftaucht und in Gruppe `k8s_api_proxy` landet.

**Bekannte Lücken/Restrisiko von `k8s_ops`:**
- [ ] **`pods: delete`/`pods/eviction: create` bleiben ein clusterweites
      Denial-of-Service-Primitiv.** Jedes Mitglied kann jeden Pod in jedem Namespace
      löschen/evicten (z. B. den CNPG-Primary und damit ein Failover auslösen). Das ist
      der bewusst akzeptierte Preis von Requirement (a) — es liest oder schreibt aber
      keine Credentials.
- [ ] **Re-Trigger für Backup-CronJobs fehlt.** Ohne `jobs: create` kann `k8s_ops` einen
      gescheiterten Backup-Lauf nicht mehr manuell nachstoßen, nur noch das gescheiterte
      Job-Objekt löschen. Bewusst in Kauf genommen, siehe `rbac.yaml`-Kommentar; ein
      separater, eng auf einen einzigen Namespace gescopeter Weg (Role statt ClusterRole,
      plus ValidatingAdmissionPolicy gegen Secret-Mounts/`serviceAccountName`) wäre denkbar,
      ist aber nicht Teil dieses Fixes.
- [ ] **Hängenden ArgoCD-Sync abbrechen fehlt.** Muss aktuell durch jemanden mit direktem
      ArgoCD-Zugriff (Admin) erfolgen, bis ArgoCD-SSO + `argocd-rbac-cm`-Policy existieren.

**Bekannte Lücken von `k8s_readonly`:**
- [ ] **`pods/log` clusterweit.** In `view` enthalten und für „alles lesen" nötig — aber der
      kube-API-Proxy loggt Werte verworfener Header, u. a. `Authorization`. Wer mit einem
      echten Token gegen den Proxy geht, schreibt ihn in dessen Log, und `k8s_readonly` darf
      das Log lesen. Upstream-Patch oder `pods/log` im netbird-Namespace ausnehmen.
      Generell können CNPG-/Renovate-/Authentik-Logs Credentials enthalten.
- [ ] **`aggregate-to-view` ist ein Fremdkanal.** Jedes Chart kann Rechte in `view` schieben;
      mariadb-operator aggregiert `k8s.mariadb.com/*` als Wildcard, victoria-metrics-operator
      `VMUser` (Klartextfelder `password`/`bearerToken`). Bei Chart-Bumps prüfen.
- **ConfigMaps und PodSpecs** sind lesbar (inhärent zu `view`). Credentials gehören in Secrets.
- `k8s_readonly` darf RBAC-Objekte lesen und ist damit auch eine **Aufklärungs-Rolle**.

**Restrisiko (inhärent, dokumentiert statt behoben):**
- Der Operator behält clusterweit `get/list/watch/create/patch/update/delete` auf **Secrets**
  (Chart-RBAC, solange `netbirdAPI.keyFromSecret` gesetzt ist). Zusammen mit `deployments`-
  und `serviceaccounts`-Vollzugriff ist das **ein** API-Call bis Cluster-Admin. Der
  netbird-Namespace ist damit Tier-0.
- Der ClusterProxy-Controller legt das NetBird-**Management-API-Token** als Secret im Cluster
  ab. Wer es liest, hängt sich in NetBird selbst in `k8s_admin` — ohne Spur im Kubernetes-Audit-Log.
  Token daher mit Ablaufdatum führen und rotieren.
- [ ] Erwägen: `k8s_admin` statt auf `cluster-admin` auf eine Rolle binden, die RBAC-Objekte
      und die Verben `escalate`/`bind`/`impersonate` ausspart.
- [ ] Break-glass-Pfad **ohne** NetBird vorhalten (`talosctl kubeconfig`, offline).
- [ ] API-Server-Audit-Logging mit Impersonation-Feldern aktivieren — bei Impersonation ist
      das die einzige Stelle, an der die handelnde Identität auftaucht.

---

## 18. Metrics Server (`kubectl top`, HPA)

**Dateien:** `infrastructure/base/metrics-server/*`

**Verdrahtet:** Chart `metrics-server` 3.13.1 liefert die `metrics.k8s.io`-APIService,
damit `kubectl top` und bestehende HPAs (z. B. Collabora) wieder Werte statt `<unknown>`
bekommen.

- **Talos-Besonderheit:** Kubelet-Serving-Zertifikate werden auf Talos rotiert und sind
  i. d. R. nicht von einer CA signiert, der metrics-server vertraut → Scraping schlägt sonst
  mit x509-Fehlern fehl. Da kein `kubelet-csr-approver` (oder ein anderer Signer für
  vertrauenswürdige Kubelet-Serving-Certs) im Cluster läuft, nutzt `values.yaml` den
  pragmatischen, verbreiteten Workaround `--kubelet-insecure-tls`: Traffic zum Kubelet bleibt
  TLS-verschlüsselt, nur die Zertifikatsprüfung entfällt.

**Offen:**
- [ ] Sichere Alternative erwägen: `kubelet-csr-approver` (o. ä.) ausrollen, damit Kubelets
      signierte Serving-Certs bekommen, dann `--kubelet-insecure-tls` entfernen.

---

## Vor dem ersten `argocd app sync` lokal prüfen

```bash
just build   # kustomize build --enable-helm über alle overlays
just test    # + kubeconform Schema-Validierung
just lint    # yamllint
just secrets-check   # echte Secrets verschluesselt, Blueprint-Platzhalter warnen
just guardrails      # Agent-/GitOps-Sicherheitschecks
just validate        # gesamtes CI-Gate
```
