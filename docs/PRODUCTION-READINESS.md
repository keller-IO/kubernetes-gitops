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

**Autoupdate (18.10.2026):** SUC und zielnode-bezogenes Prepare sind implementiert,
Live-Cluster geprueft: 8 Ready-Nodes, Talos 1.13.4 / K8s 1.36.0; Storage-Bindung
und NetBird-Webhook-Ausnahme bestaetigt. **Noch nicht aktiviert:** wrk4 ist schon
cordoned; neun CNPG-Singletons, fehlende N-1-Kapazitaet fuer HA3 und fehlgeschlagene
Mailman-/Mastodon-Backups verhindern Worker-Freigabe. Zusaetzlich Talos-mTLS,
Schematic/Erweiterungen, etcd-Recovery und In-Cluster-API-Erreichbarkeit abnehmen.
Die CPs cp1/cp3 sind nach Ende der bestehenden Wartung die kleinsten Canary-
Kandidaten, ohne pauschale Worker-DB-Skalierung. Details und Zahlen:
[Live-Abnahme](runbooks/talos-live-audit-2026-10-18.md),
[Talos-Runbook](runbooks/talos-autoupdate.md),
[Learnings](learnings/talos-upgrade-drain-safety.md).

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
- [ ] Bootstrap-Reste aufraeumen und Tofu-Bootstrap angleichen (24.10.2026): Dex und
      Notifications aus dem Erst-Bootstrap (Chart 9.5.21) laufen ungetrackt weiter.
      Manuelles Aufraeumen sowie `dex`/`notifications.enabled = false` und
      `argocd_chart_version` auf die GitOps-Minor in `argocd.tf`:
      `docs/learnings/argocd-bootstrap-reste-dex-notifications.md`.
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
- [x] Direkter WAN-Cutover auf `192.168.2.246` am 13.09.2026 vollzogen;
      `192.168.2.15` ist aus dem Web-Pfad entfernt und VM 107 gestoppt. Details
      und Abnahmemessungen stehen in `docs/runbooks/docker15-retirement.md`.
      `192.168.23.20` bleibt ein gestoppter DR-Edge fuer ein moegliches Routing
      ueber Potsdam.
- [ ] WAN2 (185.89.37.138, InternetNord) ist seit 24.10.2026 05:43 UTC von aussen
      nicht erreichbar. `halbe`, `mail` und jit.social zeigen seitdem auf die
      Telekom (87.191.135.42). Offen: WAN2 an der UDM pruefen, die IPsec-Strecke
      Halbe↔Potsdam (`vti66`) auf die Telekom legen, entscheiden, welche Namen
      wohin gehoeren ([Learning](learnings/restore-klon-ueber-vpn.md)).

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

**Dateien:** `infrastructure/base/{storage,ceph-csi,snapshot-controller}/*`, jedes
`storageClassName:` / `storageClass:` in den Apps

**Offen:**
- [ ] Existierende Ceph-StorageClass-Namen verifizieren und Manifeste angleichen
      (`ceph-rbd` = RWO, `ceph-fs` = RWX). Doppelte Klassen löschen, wenn Ceph sie schon liefert.
- [ ] S3/RGW: Bucket-StorageClass-Namen für `ObjectBucketClaim` setzen (`ceph-bucket`).
- [x] CephFS-CSI-Treiber ausgerollt (06.09.2026): Chart `ceph-csi-cephfs` 3.17.0
      neben `ceph-csi-rbd`, eigene Ceph-Identitaet `client.kubernetes-cephfs`
      (`mds allow rw fsname=cephfs`, kein RBD-Zugriff — gegengeprueft), Secret
      `csi-cephfs-secret`. Die StorageClass `ceph-fs` zeigte bis dahin ins Leere:
      deklariert, aber ohne Provisioner — PVCs blieben dauerhaft `Pending`.
- [ ] RWX (CephFS) dort bestätigen, wo mehrere Replicas teilen (paperless media, wordpress wp-content).
- [x] Cross-Node-RWX verifiziert (06.09.2026, Wegwerf-PVC in `cephfs-abnahme`):
      zwei Pods auf kellerio-wrk1 und -wrk3 am selben Volume; Schreiben/Lesen in
      BEIDE Richtungen, gleichzeitiges Anhaengen ergab 100 Zeilen (50+50, keine
      verlorenen Schreibvorgaenge), 20 MiB mit 476 MB/s sofort cross-node sichtbar.
      Mount ist der Kernel-Client (`kubernetes-cephfs@<fsid>.cephfs=/volumes/csi/...`).
      Loeschen des PVC hat das Subvolume auf Ceph mit entfernt.
- [ ] **Abnahme unvollstaendig:** CSI-Recovery nach einem kontrollierten
      Node-Reboot steht aus — MDS-Session und reales Datei-I/O danach explizit
      verifizieren (`docs/learnings/external-cephfs-client-stall-recovery.md`,
      Punkte 5 und 6). Reboot-Fenster noch festzulegen. **Bis dahin keine
      produktiven RWX-Volumes** — expense-tracker bleibt auf ceph-rbd/replicas 1.
- [ ] Default-StorageClass festlegen (aktuell `ceph-rbd`).
- [ ] CSI-Snapshot/Restore mit einem Wegwerf-`ceph-rbd`-PVC testen. API,
      Controller und `ceph-rbd-retain` sind verdrahtet; produktive Snapshots erst
      nach erfolgreichem Restore-Test anlegen.

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

**Bewusster Talos-Scope:**
- [x] `kubeControllerManager`, `kubeScheduler` und `kubeEtcd` sind deaktiviert:
      Scheduler/Controller-Manager binden ihre Metriken nur an `127.0.0.1`, und die
      Talos-etcd-Pods entsprechen nicht dem Chart-Selector. Der Render-Check verhindert
      Services, VMServiceScrapes und Regelgruppen fuer diese unerreichbaren Ziele.

**Offen:**
- [ ] Grafana-Admin-Passwort aus SOPS-Secret statt Klartext (`adminPassword`).
- [x] **Alertmanager-Receiver konfiguriert:** Email an `jit-list@jitmail.de` über `192.168.2.209:25`
      (`require_tls: true`, TLS-Servername
      `mx02.jitcreatives.de`); Watchdog und InfoInhibitor bleiben absichtlich
      auf `null`. Gerenderte Config-Prüfung mit `amtool` und SMTP-Banner/EHLO-
      Probe aus dem Alertmanager-Pod waren erfolgreich; STARTTLS und das
      TLS-1.3-Zertifikat wurden vom Host geprüft. Die Live-Abnahme nach Merge
      wird im zugehörigen PR festgehalten; siehe [Inspektion](runbooks/cluster-inspection-2026-10-20.md).
- [ ] **Mailzustellung für unterschiedliche Alerts abnehmen.** Der Relay wies
      am 21.10. die erste Nachricht mit dem langen Standardbetreff nach `DATA`
      als Spam ab; eine spätere Nachricht erreichte die JIT-Liste. Ein kurzer
      Betreff und ein Klartextteil werden im
      [Learning](learnings/alertmanager-mail-rspamd-rejection.md) beschrieben.
- [x] **Recording Rule `count:up0` korrigiert:** Bei vorhandenen, erfolgreichen
      Targets entsteht eine Nullserie, bei komplett fehlenden Targets weiterhin
      keine Serie. Die gerenderte Regel wurde geprüft.
- [ ] Retention/Storage-Size an Clustergröße anpassen.
- [ ] ServiceMonitor/PodMonitor-Scrape für CNPG, MariaDB, Valkey, NGINX, Cilium prüfen.
- [ ] Alerts fuer CephFS-CSI-Mount-/Sessionfehler und das Alter des letzten
      erfolgreichen Backups einrichten; ein vorhandener Zeitplan reicht nicht.

---

## 11. Kubernetes MCP Server

**Dateien:** `infrastructure/base/kubernetes-mcp/*`

**Offen:**
- [ ] `htpasswd`-Wert in `secret.sops.yaml` generieren + verschlüsseln:
      `htpasswd -nb mcp <starkes-passwort>` → in `stringData.htpasswd` eintragen.
- [ ] Fuer den Rulesync-MCP-Preset `KELLER_KUBERNETES_MCP_AUTH` in der Agent-Umgebung
      auf `Basic base64(mcp:<passwort>)` setzen; die Zugangsdaten nicht committen.
- [x] RBAC read-only halten: keine Write-Verben, kein Secret-Zugriff. CI prüft das über
      `just guardrails`.
- [x] Kein `nodes/proxy`: Bereits GET erlaubt laut [Kubernetes-RBAC-Dokumentation](https://kubernetes.io/docs/concepts/security/rbac-good-practices/#access-to-proxy-subresource-of-nodes)
      die Ausführung von Befehlen über die Kubelet-API. `just test` blockiert diese
      Berechtigung einschließlich Wildcards, Trivy prüft das gerenderte RBAC.
      Die zugehörige Ausnahme KSV-0047 entfällt, die Security-Baseline sinkt von 277 auf 276 Findings.
      Beim MCP-Server v0.0.61 entfallen dadurch Node-Logs und die Kubelet-Statistikzusammenfassung;
      Pod-Logs und Node-/Pod-Metriken über `metrics.k8s.io` bleiben erlaubt.

---

## 12. Backup & Disaster Recovery

**Verdrahtet (Blaupause):** DB-Backups sind in den Manifesten aktiv — täglich 02:00 nach Ceph S3,
30 Tage Retention.
- **CNPG** (roundcube, paperless, forgejo, mastodon, mailman): `backup.barmanObjectStore` im
  jeweiligen `database.yaml` (bzw. `postgres.yaml`) + `ScheduledBackup` in `backup.yaml`.
  Continuous WAL + base → PITR.
- **Ausnahme mastodon-search (Elasticsearch 8.19):** bewusst ohne Backup. Der Index
  ist aus Postgres per `tootctl search deploy` rekonstruierbar; die PVC (10Gi `ceph-rbd`)
  trägt `Prune=false,Delete=false`. Security ist in ES abgeschaltet, Schutz = CiliumNetworkPolicy
  `mastodon-search`; `node.store.allow_mmap=false` (kein `vm.max_map_count` auf Talos).
  Mastodon wird erst in PR 2 angebunden, siehe `docs/runbooks/mastodon-migration.md`.
- **MariaDB** (kimai, wordpress): `Backup` CR in `apps/base/<app>/backup.yaml` (logischer Dump).
- **S3-Creds**: `<app>-backup-s3` Secret in jeder `secret.sops.yaml`.
- **PVC-Checkpoints**: CSI-`VolumeSnapshot` für `ceph-rbd` ist mit
  `deletionPolicy: Retain` vorbereitet. Diese Snapshots liegen im selben Ceph und
  ersetzen kein Offsite-Backup.
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
- [ ] Integrations-Pilot (`scripts/ci/integration/`) um eine MariaDB-Instanz erweitern —
      Operator-Bumps sind bisher ungetestet ([Learning](learnings/mariadb-operator-stufenweises-upgrade.md)).
- [ ] MariaDB-Server 11.4.5 → 11.8.9 → 12.3.3 (LTS) stufenweise mit Pre-Upgrade-Dumps — Stufe 11.8.9 seit 21.10.2026 live, 12.3.3 offen
      ([Runbook](runbooks/mariadb-lts-upgrade.md)); danach `pre-upgrade-backup.yaml` entfernen.
- [ ] DR-Overlay `infrastructure/overlays/disaster-recovery/` mit `bootstrap.recovery` anlegen.
      Ein Restore aus Garage läuft ungedrosselt über das VPN nach Potsdam: Leitung
      einplanen und `# guardrails: allow-garage-restore` setzen
      ([Learning](learnings/restore-klon-ueber-vpn.md)).
- [ ] PVC-Daten (paperless data/media, forgejo repos, wordpress wp-content,
      Mailman-Dateien) nach dem CSI-Smoke-Test per quiesced Snapshot absichern.
      Fuer die SMB-Scanner-Inbox und Ceph-Ausfaelle zusaetzlich eine
      Offsite-Strategie festlegen.
- [ ] Restore-Abläufe aus `docs/runbooks/backup-restore.md` je Backend testen.

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
- [x] Renovate-Image in `apps/base/renovate/cronjob.yaml` auf
      `renovate/renovate:44.176.3` aktualisiert. Der CronJob bleibt wegen des
      abgelaufenen GitHub-Tokens suspendiert (`suspend: true`).
- [x] Renovate läuft gegen GitHub (`keller-IO/kubernetes-gitops`) und ignoriert
      `.forgejo/**`.
- [x] `# renovate:`-Kommentare an Helm-, Docker- und Workflow-Versionen werden
      durch `customManagers` abgedeckt.
- [x] CI führt `scripts/ci/guardrails.sh` aus; lokal bündelt `just validate`
      dieselben statischen Prüfungen wie GitHub: Guardrails, Lint, Secret-Check,
      synthetisches SOPS/KSOPS-Rendering, strikte Schemas, HPA-, PVC- und Security-Gates.
- [x] Kind/ArgoCD-Piloten für Neuinstallation und Upgrade von Gatus/Goloom sind
      über `just integration` und die CI-Matrix verdrahtet; Details und Grenzen:
      [CI-Sicherheit](runbooks/ci-safety.md), [Integration](runbooks/ci-integration.md).
- [ ] Produktive Kubernetes-Version read-only gegen den CI-Pin 1.36.1 prüfen.
- [x] Alle 14 bisherigen PVC-Lücken geschlossen: direkt von ArgoCD verwaltete
      App-PVCs tragen `Prune=false,Delete=false`, ohne Retention-Ausnahmen.
      Schutz greift nach dem Sync gegen Argo-Prune und App-Löschung; Namespace-
      Löschung und Storage-Ausfälle brauchen weiterhin Backups und Restore-Tests.
- [ ] Initiale 277 Security-Befunde systematisch abbauen; Security-Ausnahmen
      laufen am 18.01.2027 ab.
- [ ] Produktions-Health nach Merge als Automerge-Schranke und regelmäßige
      isolierte Backup-Restore-Tests ergänzen.
- [x] Guardrails blockieren `:latest`, `imagePullPolicy: Always`, verdächtige
      Klartext-Secrets, mutierende Cluster-Kommandos in Automation und Write-RBAC
      für den Kubernetes MCP Server.

**Beispiel** — Renovate gegen GitHub (`apps/base/renovate/config.js`):
```js
module.exports = { platform: 'github', repositories: ['keller-IO/kubernetes-gitops'] };
```

---

## 14. Mail (extern)

**Dateien:** `apps/base/roundcube/workload.yaml`,
`apps/base/mastodon/{values,secret.sops}.yaml`, `apps/base/mailman/{workload,secret.sops}.yaml`

**roundcube-dev (`dev.jitmail.de`)** war eine bewusst wegwerfbare Zweitinstanz fuer den Cutover
mail04 -> mail05 und ist nach dessen Abschluss ersatzlos entfernt worden (App, Ingress,
DNS-Record und der `jitmail.de`-Eintrag im RFC2136-Solver). Der Cutover ist durch; `jitmail.de`
wird von der regulaeren roundcube-Instanz bedient, die ohnehin auf mail05 zeigt.

**Offen:**
- [ ] Externen IMAP/SMTP-Host in roundcube setzen (`ROUNDCUBEMAIL_DEFAULT_HOST`/`SMTP_SERVER`).
- [x] Nach dem mail05-Cutover: `roundcube-dev` samt Ingress, DNS-Record `dev.jitmail.de` und
      dem `jitmail.de`-Eintrag im RFC2136-Solver wieder entfernt.
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
| **roundcube** | `apps/base/roundcube/` | Legacy-Domains `roundcube.savar.de`, `mail.steinba.ch`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de` und `webmail.daec-berlin.de` sind im Overlay als eigener Ingress ergänzt (`roundcube-jitmail`, DNS-01). `mail.steinba.ch` hat seit #389 einen eigenen Ingress `roundcube-jitmail-preload` mit eigenem Zertifikat `roundcube-steinbach-tls` (HTTP-01, `http01-edit-in-place`; der Challenge-Pfad ist in `clusters/main/appset-apps.yaml` von der Drift-Erkennung ausgenommen). Die Erstausstellung (26.10.2026, #389) lief mit `ssl-redirect: "false"`, also kurz ohne gültiges Secret; seit #390 `"true"`. Der Challenge-Pfad ist erst seit #390 von der Drift-Erkennung ausgenommen. Offen in `legacy-proxy`: `jitcloud-preload` (`cloud.steinba.ch`, `cloud.naturkindergarten-moehringen.de`) trägt noch das vorgeladene Traefik-Zertifikat, Ablauf **30.11.2026**. PostgreSQL-Schemafehler der historischen pgloader-Migration am 27.07. repariert (`postgres-schema-repair-20260727.sql`). Externen IMAP/SMTP setzen; `managesieve`-Backend prüfen; Session-Cache auf Valkey umstellen (config). |
| **collabora** | `apps/base/collabora/` | `aliasgroups`-Regex auf reale WOPI-Hosts; Admin-Passwort; WOPI-Client (z.B. Nextcloud) anbinden. |
| **eurooffice** | `apps/base/eurooffice/` | JWT-Secret (`jwt-secret`, bereits generiert/verschlüsselt) in der Nextcloud-Connector-App spiegeln (`occ config:app:set eurooffice ...` auf nc01/nc02-dev, URL `https://eurooffice.jit.services`); All-in-One-Image (interne PG/RabbitMQ/Redis) — bei >1 Nextcloud auf offizielles Kubernetes-Docs-Chart + CNPG umstellen (braucht CephFS-RWX); Erststart dauert (Font-Cache), Healthcheck `/healthcheck`. Zusaetzlich oeffentlich als `eurooffice.jit-creatives.de` (explizites CNAME `halbe` auf dns01, 23.10.2026), damit die externe Statusseite pruefen kann; Nextcloud nutzt weiter `eurooffice.jit.services`. |
| **paperless-ngx** | `apps/base/paperless-ngx/` | Version 2.20.15 laeuft produktiv und erfuellt den verpflichtenden Zwischenstand vor 3.x. Vom Phase-1-Stand am 02.08.2026 bestehen Export und PVC-Snapshots; das CNPG-Backup ist nach 30 Tagen abgelaufen, daher ist kein punktgenauer 2.20.6-Rollback mehr moeglich. Die CNPG-Retention ist fuer den neuen 3.x-Recovery-Punkt auf 90 Tage erhoeht. Vor 3.x zuerst die wiederholten Celery-Child-Start-Timeouts stabilisieren, danach unter erzwungener Schreibsperre einen echt getesteten Recovery-Punkt erzeugen. Aktuelles Ziel ist 3.2.1; dabei SMB-Polling auf `PAPERLESS_CONSUMER_POLLING_INTERVAL` migrieren. Vollstaendiger Ablauf: `docs/runbooks/paperless-v3-upgrade.md`. Scanner-Inbox `//192.168.2.75/scanner` ist via SMB-CSI eingebunden und wird alle 10 Sekunden abgefragt. Externe Domain `paperless.savar.de`; TLS terminiert am Cluster-Ingress. Der Upload-Fortschritt laeuft per WebSocket ueber `/ws/status/`; dafuer braucht der Ingress `nginx.org/websocket-services: paperless-paperless-ngx`, und der Wert muss dem gerenderten Service-Namen entsprechen (bei Chart-Bumps im gerenderten Ingress pruefen; ohne die Annotation antwortet der Ingress mit 200 statt 101 und der Upload-Dialog haengt). Web-Uploads und OCR-Zwischendateien liegen in `PAPERLESS_SCRATCH_DIR` (`/tmp/paperless`), einem emptyDir mit `sizeLimit: 10Gi`. Es uebersteht OOM-/Container-Neustarts, aber keinen Pod-Wechsel; Rollouts und Node-Drains deshalb nur, wenn keine Consume-Tasks, Uploads oder Exporte laufen und die Verarbeitungs-Warteschlange leer ist. Speicher: Request 1Gi, Limit 3Gi (OOMKilled bei 1536Mi am 26.10.2026 waehrend eines Massen-Uploads). Admin + SECRET_KEY; OIDC-JSON `server_url`/`secret`; RBD-Snapshot/Restore vor dem Upgrade testen. |
| **forgejo** | `apps/base/forgejo/` | Admin-Secret; SSH-Service exponieren (LB/NodePort); OIDC-Provider in Forgejo anlegen; LFS→S3 optional. |
| **renovate** | `apps/base/renovate/` | Forgejo-Token; `autodiscover` vs. feste Repo-Liste; Schedule abstimmen. |
| **wordpress-1/2/3** | `apps/base/wordpress/` + `apps/overlays/main/wordpress-{1,2,3}/` | Pro Instanz Secret + Host (in Overlay gepatcht); „Redis Object Cache"-Plugin installieren; `mariadb.enabled:false` + externalDatabase final schalten. |
| **mastodon** | `apps/base/mastodon/` | `jit.social` ist seit 19.10.2026 im Cluster in Betrieb; Web, Streaming und Sidekiq `default` laufen mit je zwei Repliken und PDB, der Scheduler einzeln. Valkey bleibt ein Single Point of Failure ([Betriebsrunbook](runbooks/mastodon-betrieb.md)). 4.7.3 läuft seit 25.10.2026 (#386), Messwerte im [Runbook](runbooks/mastodon-migration.md), Abschnitt „4.6.9 → 4.7.3“. Restore-Test aus `backup-mastodon` am 25.10.2026 bestanden (Klon in Potsdam). Registrierung seit 25.10.2026 geschlossen, weil Spam-Anmeldungen Bestätigungsmails über `mail.jit-creatives.de` verschickten ([Learning](learnings/mastodon-anmeldespam-mailversand.md)). Offen: die 8 bestätigten, wartenden Konten in der Moderation prüfen; Retention überwachen; Elasticsearch für Volltextsuche bei Bedarf anbinden. |
| **gatus** | `apps/base/gatus/` | `gatus-oidc`-Secret mit Keycloak-Client-Secret füllen; `issuer-url`/`redirect-url`/`client-id` auf reale Domain. Alle kanonischen Web-App-Endpunkte sind eingetragen; Paperless wird über `paperless.savar.de` geprüft und folgt dem Login-Redirect bis HTTP 200. Gewünschte Legacy- und Alias-Domains bei Bedarf als eigene Routengruppe ergänzen. Historie persistent in Postgres (`monitoring-pg`, DB `gatus`, Secret `gatus-db`; ADR 0008). |
| **gatus-public** | — (extern) | Seit 23.10.2026 nicht mehr im Cluster: `status.jit-creatives.de` läuft auf `prometheus.radiotux.de` (Ansible-Rolle `gatus_public` in `jit/ansible`, docker compose, SQLite, nginx + certbot, Signal-Alarme über die vorhandene signal-api). Radio und EuroOffice werden über `radio.jit-creatives.de` / `eurooffice.jit-creatives.de` geprüft. Der interne Gatus prüft umgekehrt `status.jit-creatives.de/health`. DB, Rolle und Secret `gatus_public` in `monitoring-pg` sind entfernt. |
| **kite** | `infrastructure/base/kite/` | `kite-secrets` füllen (`JWT_SECRET`/`KITE_ENCRYPT_KEY` via `openssl rand -hex 32`, `OAUTH_CLIENT_SECRET` == Keycloak-Client-Secret); `issuer`/`clientId` setzen; RBAC-Rollen-Mapping für OIDC-User; PVC-StorageClass prüfen. Daten in Postgres (`monitoring-pg`, DB `kite`, Secret `kite-db`; ADR 0008), SQLite-Stand bleibt auf PVC `kite-storage`. Migrations-Hooks unter `migration/` nach erfolgreicher Umstellung entfernen. |
| **monitoring-db** | `infrastructure/base/monitoring-db/` | Gemeinsamer CNPG-Cluster `monitoring-pg` (2 Instanzen) für Gatus intern und Kite (ADR 0008; `gatus_public` am 23.10.2026 entfernt, siehe `docs/learnings/cnpg-managed-role-drop-kein-retry.md`). Backup nach Garage `s3://backup-monitoring-db/cnpg/` (eigener Bucket/Key, 30d, täglich 02:30); nach dem ersten Sync Base-Backup anstoßen und `ContinuousArchiving=True` prüfen; Ressourcen nach einer Woche Betrieb gegen `kubectl top` prüfen. |
| **mailman** | `apps/base/mailman/` | Upgrade auf 0.5.2 ist produktiv; PostgreSQL-Zeitspalten wurden repariert, Web-Startup-Limit nach zwei OOMs auf 2 GiB erhöht. Core, LMTP und der ausgehende Rundlauf sind verifiziert. Der Whoosh-Volltext-Neuaufbau scheiterte an Speicher-, Segment- und Laufzeitgrenzen; Web wird mit dem bisherigen Index im produktiven PVC wieder betrieben. Suche, Queue und Restarts beobachten; ein neues Suchverfahren separat testen. |
| **icecast** | `apps/base/icecast/` | Source/Admin/Relay-Passwörter setzen; Source-Clients auf HTTPS-URL und Source-Passwort umstellen; Listener-Limit nach Stream-Profil prüfen (Ingress-Timeouts/Buffering für Live-Streaming sind gesetzt: `proxy-buffering off`, 3600s Read/Send-Timeout). Oeffentlicher Name `radio.jit-creatives.de` (explizites CNAME `halbe` auf dns01, 23.10.2026); `ICECAST_HOSTNAME` bleibt `radio.jit.services`. |
| **phpmyadmin** | `apps/base/phpmyadmin/` | Legacy-Domains `phpmyadmin.savar.de`/`phpmyadmin.jit-creatives.de` sind im Overlay ergänzt; TLS endet dort am Legacy-Traefik. Zugriff seit 22.09.2026 per IP-Allowlist (`nginx.org/server-snippets`: RFC1918 + NetBird) auf interne Netze begrenzt, fuer alle drei Hosts -- vorher von extern per Host-Header erreichbar (HTTP 200); nur dedizierte DB-User statt Root verwenden; Default-DB-Host `kimai-mariadb.kimai.svc.cluster.local` prüfen; weitere Ziele als FQDN eintragen. |
| **nextcloud-yealink-phonebook** | `apps/base/nextcloud-yealink-phonebook/` | Liest das Nextcloud-Adressbuch alle 15 Minuten per CardDAV und stellt tokenisiert Remote- sowie T46S-Local-Directory-XML bereit. Die OEM-Firmware `66.85.193.13` blockiert Remote Phone Book und verwirft `local_contact.data.url`; deshalb wurden 17 Kontakte einmalig als lokales Telefonbuch importiert und auf dem Display unter `Kontakte > Alle Kontakte > Eingeben` validiert. Automatische Telefonaktualisierung bleibt offen und erfordert Kontrolle des PnP/DHCP-Provisionierungsservers oder einen getesteten Web-Upload-Client. Details: `docs/learnings/yealink-t46s-oem-phonebook.md`. |
| **matomo** | `apps/base/matomo/` | Selbst gehostete Web-Analyse fuer `www.jit-creatives.de`. Oberflaeche NUR intern auf `matomo.jit.services`, seit 22.09.2026 per IP-Allowlist erzwungen (vorher von extern per Host-Header erreichbar); die Allowlist prueft seit 23.10.2026 den TCP-Peer (`$realip_remote_addr`), weil `allow`/`deny` auf die per XFF wiederhergestellte Besucher-IP vom 22.09. bis 23.10. jeden externen Tracker-Aufruf ueber mgmt02 mit 403 abwies; der Tracker laeuft first-party als `/stats/` durch die nginx auf mgmt02 (kein oeffentlicher Ingress, kein Traefik-Zertifikat noetig). **Einmalig nach dem ersten Sync:** Installations-Assistent durchlaufen, dann in *Administration > Datenschutz* IP-Maskierung auf 2 Bytes, DoNotTrack respektieren und Rohdaten-Loeschung nach 90 Tagen setzen — diese drei liegen als PrivacyManager-Optionen in der Datenbank und lassen sich NICHT ueber `config.ini.php` vorgeben. Cookieless und DNT werden zusaetzlich im Tracking-Snippet erzwungen. Updates nur ueber das Image: der initContainer `upgrade-code` tauscht beim Versionswechsel den Code auf dem PVC aus und fuehrt `core:update` aus (vorher blieb der Code auf dem Stand der Erstinstallation), Auto-Update in der Oberflaeche ist aus. Offen: Archivierung laeuft browser-getriggert (Default); ein `core:archive`-CronJob scheitert am RWO-Volume und braucht erst ein API-Token. Ablauf: `docs/runbooks/matomo-setup.md`. |
| **ciso-assistant** | `apps/base/ciso-assistant/` | GRC-Plattform, v. a. fuer das Verzeichnis von Verarbeitungstaetigkeiten (Art. 30 DSGVO). NUR intern auf `grc.jit.services`, per IP-Allowlist im Ingress erzwungen (RFC1918 + NetBird), weil 443 vom Router auf denselben LB zeigt. Postgres via CNPG (`ciso-assistant-pg`, Backup `s3://backup-ciso-assistant/cnpg/`, eigener Garage-Bucket und -Key mit RW nur darauf). **In Betrieb seit 22.09.2026** (#198). Keycloak-Client `ciso-assistant` im Realm `bgt` angelegt (Secret in `oidc.sops.yaml` und auf auth01 `/root/ciso-assistant-oidc-client-secret`); SSO noch in der App-UI eintragen. Evidenzen im Ceph-RGW-Bucket `ciso-assistant-evidence` (RGW-User mit 20-GiB-Quota), Mail ueber mx02 per IP-Relay -- neue Nodes in `mx_gateway_trusted_clients` nachziehen. Evidenz-Offsite-Kopie per rclone-CronJob 03:30 nach Garage `backup-ciso-assistant/evidence/` (30 Tage Archiv, Quota 50 GiB). Offen: Alert bei fehlgeschlagenem CronJob; `/login`-502 (nginx-Header-Puffer) und Resources mit #201 behoben, nach einer Woche gegenpruefen; expliziter ClouDNS-A-Record fuer `grc.jit.services` (siehe learnings/wildcard-dns01-empty-non-terminal.md). Ablauf: `docs/runbooks/ciso-assistant-setup.md`. |
| **goloom** | `apps/base/goloom/` | Social-Media-Planung fuer Binaergewitter, Helm-Chart direkt aus `Goloom-App/goloom` am Git-Tag v0.3.0, Image v0.3.0. ArgoCD `app-goloom` kombiniert das Upstream-Chart mit lokalen Values und Kustomize-Ressourcen; Renovate gruppiert Git-Tag und Image gemeinsam. Der lokale ServiceAccount `goloom` unterbindet Token-Automount, Pod-/Container-Sicherheitskontexte stehen in den Values, Datenbank seit 18.10.2026 Postgres (CNPG `goloom-pg`, #270/#272; Migration aus SQLite mit Zeilen- und Wertevergleich verlustfrei belegt, `docs/learnings/goloom-sqlite-nach-postgres.md`), Medien auf 5-GiB-Ceph-RBD unter `goloom.binaergewitter.de`; die PVC liegt seit 17.10.2026 in `pvc.yaml` mit `Prune=false,Delete=false`, nachdem der Chart-Umstieg (#238) sie gepruned hatte (`docs/learnings/argocd-prune-pvc-bei-quellenwechsel.md`). **In Betrieb seit 14.10.2026** (#230). DNS: Cloudflare-Wildcard `*.binaergewitter.de` -> `87.191.135.42` (UDM Halbe -> `.246`), kein eigener Record noetig. TLS per namespaced Issuer `goloom-letsencrypt` (HTTP-01, `http01-edit-in-place`); Erstausstellung nur mit `nginx.org/ssl-redirect: "false"`, danach `"true"` (siehe Kommentar in `values.yaml`). Beim Sync kurzes OutOfSync, weil cert-manager den Solver-Pfad in den Ingress schreibt und selfHeal ihn zurueckdreht — erste Erneuerung (~13.12.2026) beobachten. SOPS-Secret enthaelt Encryption Key und Bootstrap-Token; Bootstrap-Admin `admin@binaergewitter.de` (bestaetigt). Backup nach Garage `s3://backup-goloom/` (eigener Key): Datenbank per CNPG-Barman (`cnpg/`, 02:50, 30 Tage PITR), Medien per CronJob `goloom-backup` 03:45 (rclone, Archiv 30 Tage); alte SQLite-Staende unter `sqlite/` bleiben. Ablauf in `docs/runbooks/backup-restore.md`, Abschnitt Goloom. Offen: Recovery-Test fuer `goloom-pg`, Alert bei fehlgeschlagenem CronJob. OIDC seit 15.10.2026: Keycloak-Client `goloom` im Realm `bgt` (confidential, PKCE S256, Issuer `auth.savar.de`). **Goloom legt jeden OIDC-Nutzer automatisch an, der erste wird Instanz-Admin.** Weil bgt alle Mailkonten foederiert, laesst der client-eigene Browser-Flow `goloom-browser` nur die Gruppe `goloom-users` (Client-Rolle `goloom.access`) durch, alle anderen bekommen "Deny access" (mit Testnutzer geprueft). Mitglieder werden in Keycloak gepflegt. Achtung: `POST /users` in bgt legt Nutzer im Provider `local-accounts` (MySQL db10 `keycloak.account`) an, und ein Admin-`DELETE` deaktiviert sie dort nur. Recovery-Login: `/?login=recovery` mit Bootstrap-Token. |
| **cloud-dev proxy** | `apps/base/legacy-proxy/` | `cloud-dev.savar.de` bleibt auf `nc01-dev` (`192.168.2.220`) und läuft direkt über den Cluster-LB `.246`; der Hauptdienst wird zu HTTPS/443 re-encryptet, `/push/` geht per WebSocket und Strip-Prefix an notify_push/7867. `signal.cloud-dev.savar.de` terminiert TLS im Cluster und leitet `/standalone-signaling/` per WebSocket an den HTTP-Nginx auf Talk-HPB `talk01` (`192.168.2.215:80`) weiter. EndpointSlices nach dem ArgoCD-Sync einmalig manuell anwenden; Nextcloud vertraut dem Pod-CIDR `10.244.0.0/16`. `nc02-dev` (`.221`) erst nach Erreichbarkeits- und Release-Prüfung wieder aufnehmen. |
| **litellm** | `apps/base/litellm/` | Stateless Gateway ausschliesslich fuer Blablador `alias-code`, seit 17.10.2026 vollstaendig abgenommen. Image `v1.104.0` ist per Digest, Signatur und Scan verifiziert; direkter und Gateway-seitiger Chat-/Streaming-/Tool-Contract, Request-Allowlist, exakter Proxy-Vertrag, XFF-Spoofing, Pfad-/Methodenmatrix, 413/429/503-Limits sowie Cilium-DNS-/FQDN-/SNI-Grenzen mit erfolgreicher PostSync-Probe sind abgenommen. Hermess reale Streaming-Erweiterung `stream_options: {include_usage: true}` ist direkt gegen Blablador und im netzisolierten Exact-Image-Contract abgedeckt; andere `stream_options`-Formen sowie das nicht abgenommene `reasoning_effort` bleiben verboten. Fehlende Authentifizierung liefert 401, ein vorhandener Nicht-Master-Key im datenbanklosen Modus 400 `no_db_connection`; der netzisolierte Exact-Image-Contract belegt fuer beide Chat-Ablehnungen null Providerattempts. PR #253 rotierte den Master-Key auf Secret-Revision `v2`; ArgoCD synchronisierte Revision `2f4a67d` erfolgreich, der neue Key lieferte von `hermes01` HTTP 200 und der alte Key HTTP 400 `no_db_connection`. Der explizite ClouDNS-A-Record `litellm.jit.services -> 192.168.2.246` ist seit 16.10.2026 vorhanden und autoritativ sowie oeffentlich verifiziert. Seit 18.10.2026 ist auch Hermes vollstaendig abgenommen: `hermes-blablador` ist der Primaerpfad, der kontrollierte 429-Fall wechselte fuer genau den Testturn zu `openai-codex`, der folgende Turn kehrte zu Blablador zurueck, und Rollback sowie Reaktivierung waren erfolgreich und idempotent. Architektur: `docs/decisions/0006-litellm-blablador-hermes-codex-fallback.md`. |

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

**In NetBird angelegt** (Stand 18.10.2026; nicht in Git — siehe unten warum):

| Objekt | Inhalt |
|---|---|
| Gruppe `k8s_admin` | Nutzergruppe |
| Gruppe `k8s_readonly` | Nutzergruppe |
| Gruppe `k8s_api_proxy` | Peer-Gruppe, nur die Proxy-Pods |
| Policy „Kubernetes API proxy" (seit 18.10.2026) | `k8s_admin` + `k8s_readonly` → `k8s_api_proxy`, tcp/443. **Diese Policy trägt kubectl über den Proxy.** |
| Policy „Kubernetes API access" | `k8s_admin` + `k8s_readonly` → Resource `standard` = 192.168.2.0/24, tcp/443. Zeigte ursprünglich auf `k8s_api_proxy`, seit 04.08.2026 auf die /24 — trägt kubectl über den Proxy **nicht**. |

**Vorbereitet, in NetBird noch nicht angelegt:**

| Objekt | Stand |
|---|---|
| Gruppe `k8s_ops` | RBAC dafür steht in `rbac.yaml` (siehe Rechte-Tabelle), die Gruppe existiert in NetBird aber nicht. Solange sie fehlt, kann kein Peer sie tragen, die Bindings greifen also ins Leere. Beim Anlegen zusätzlich als Quelle in die Policy „Kubernetes API proxy" aufnehmen, sonst erreicht ein reines `k8s_ops`-Mitglied den Proxy nicht. |

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
| `k8s_ops` (Gruppe noch nicht angelegt, s. o.) | `view` + `netbird-cluster-reader` + `netbird-k8s-ops-maintainer` |

NetBird kann kein „read-only" erzwingen — Policies sind L3/L4, alle Nutzergruppen bekommen
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
- [ ] **Erst sobald `k8s_ops` in NetBird angelegt und als Quelle in „Kubernetes API proxy"
      aufgenommen ist** (vorher gibt es kein Mitglied, mit dem man testen könnte):
      Erwartung ops: `delete pod`, `create pods/eviction`, `patch deployment/scale` gehen;
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
