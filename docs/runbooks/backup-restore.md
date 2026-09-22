# Runbook — Backup & Restore (Datenbanken und RBD-PVCs)

Kontinuierliche PostgreSQL-Backups der CNPG-Apps nach **Garage-S3 Potsdam**
(offsite, getrennt vom Cluster-Ceph). Eingerichtet 13.07.2026.

## Überblick

```
CNPG-Cluster (roundcube-pg, paperless-pg, forgejo-pg, mailman-pg, mastodon-pg)
  ├─ WAL-Archiving (kontinuierlich)   ─┐
  └─ ScheduledBackup (Base-Backup)    ─┴─► s3://backups/cnpg-<app>/  @ Garage
                                              http://192.168.23.21:3900
```

- **S3-Endpoint:** `http://192.168.23.21:3900` (Garage, Region `garage-potsdam`,
  Bucket `backups`). Setup-Repo: `cfgmgmt01:/root/ansible/garage-s3`.
- **Was:** Alle CNPG-Postgres-Datenbanken (Base-Backup + WAL → Point-in-Time-Recovery).
  MariaDB-Apps (kimai, wordpress) sind hier NICHT abgedeckt — separater Weg nötig.
- **Retention:** 30 Tage (`retentionPolicy` je Cluster).
- **Pfad je App:** `s3://backups/cnpg-<app>/` (roundcube, paperless, forgejo, mailman, mastodon).

## Ceph-RBD-PVC-Snapshots

`infrastructure/base/snapshot-controller/` installiert die drei stabilen
`snapshot.storage.k8s.io/v1`-CRDs und den zu Ceph CSIs
`csi-snapshotter:v8.5.0` passenden Controller. Der Ceph-RBD-Chart erzeugt die
Klasse `ceph-rbd-retain`.

Ein `VolumeSnapshot` ist ein schneller lokaler Rollback-Punkt, aber **kein
Offsite-Backup**: Quell-PVC und Snapshot liegen im selben Ceph-Pool. Vor dem
ersten produktiven Snapshot muss ein Wegwerf-PVC diese Kette vollständig
durchlaufen:

1. Markerdatei auf einem `ceph-rbd`-PVC schreiben und den schreibenden Pod stoppen.
2. `VolumeSnapshot` mit `volumeSnapshotClassName: ceph-rbd-retain` anlegen.
3. `readyToUse: true` und die beidseitige Bindung zum erzeugten
   `VolumeSnapshotContent` prüfen.
4. Einen neuen PVC per `spec.dataSource` aus dem Snapshot erzeugen.
5. Den Restore-PVC in einem Wegwerf-Pod mounten, Markerdatei lesen und eine
   Schreib-/Löschprobe ausschließlich auf dem Restore durchführen.

Bei Anwendungsdaten zuerst alle schreibenden Pods über Git auf null skalieren
und zusätzlich auf das Verschwinden der Pods und `VolumeAttachment`-Objekte
warten. RBD-Snapshots frieren ext4 nicht ein; bei laufenden Schreibern wären sie
nur crash-konsistent. Der Postgres-Pod bleibt aktiv und wird separat über das
native CNPG-Backup gesichert.

Beispiel für einen Restore-PVC:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data-restore-test
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Filesystem
  storageClassName: ceph-rbd
  dataSource:
    apiGroup: snapshot.storage.k8s.io
    kind: VolumeSnapshot
    name: app-data-checkpoint
  resources:
    requests:
      storage: 5Gi
```

Die angeforderte Größe darf nicht kleiner als `status.restoreSize` sein.
`deletionPolicy: Retain` verhindert das automatische Löschen des Ceph-Snapshots;
Aufräumen ist deshalb immer ein expliziter, geprüfter Vorgang.

## Secrets

### Standard für neue Backups (seit 22.09.2026): ein Bucket und ein Key pro App

Garage vergibt Rechte **nur pro Bucket**, nicht pro Prefix. Jeder Key auf dem
gemeinsamen Bucket `backups` kann deshalb die Backups *aller* Apps lesen,
überschreiben und löschen. Neue Backups bekommen daher:

- Bucket `backup-<app>` mit Quota,
- Key `backup-<app>`, **nur `--read --write`** auf diesen Bucket (kein `--owner`),
- Pfade im Bucket nach Art: `cnpg/`, `mariadb/`, `evidence/` …,
- SOPS-Secret `<app>-backup-s3` mit `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`, `region`.

Anlegen (auf `192.168.23.21`):
```bash
G=$(docker ps -qf name=garage | head -1)
docker exec $G /garage bucket create backup-<app>
docker exec $G /garage bucket set-quotas --max-size 20GiB backup-<app>
docker exec $G /garage key create backup-<app>
docker exec $G /garage bucket allow --read --write backup-<app> --key backup-<app>
```

Secret befüllen, ohne dass der Klartext im Terminal oder auf der Platte landet
(im Repo-Root ausführen; `.sops.yaml` greift über `--filename-override`):
```bash
F=apps/base/<app>/backup-s3.sops.yaml   # bzw. secret.sops.yaml
ssh root@192.168.23.21 'docker exec $(docker ps -qf name=garage | head -1) \
    /garage key info --show-secret backup-<app>' \
  | awk -F': *' '/^Key ID/{id=$2} /^Secret key/{sk=$2} END{
      print "apiVersion: v1\nkind: Secret\nmetadata:\n    name: <app>-backup-s3\n    namespace: <ns>\ntype: Opaque\nstringData:"
      print "    ACCESS_KEY_ID: " id "\n    SECRET_ACCESS_KEY: " sk "\n    region: garage-potsdam"}' \
  | sops -e --filename-override "$F" --input-type yaml --output-type yaml /dev/stdin > "$F.new" \
  && mv "$F.new" "$F"
```
Liegt das Backup-Secret in einer gemeinsamen `secret.sops.yaml`, stattdessen
`sops <datei>` öffnen und die drei Werte von Hand ersetzen.

Vor dem Merge den Key mit `curl --aws-sigv4 "aws:amz:garage-potsdam:s3"` prüfen:
PUT/GET/DELETE im eigenen Bucket → 200/204, LIST auf `backups` → **403**.

Referenz: `ciso-assistant` (PR #198) → `s3://backup-ciso-assistant/cnpg/`.

### Ist-Stand der Keys (live 22.09.2026)

| Key | Rechte | Nutzer |
|---|---|---|
| `cnpg-backups` (`GK4abeaff…`) | **RWO** auf `backups` | roundcube, paperless, forgejo, mailman, mastodon (CNPG); kimai, wordpress-1/-2/-3, matomo (MariaDB) |
| `cnpg-crowdsec`, `cnpg-expense` | RW auf `backups` | je ein CNPG-Cluster, aber auf dem gemeinsamen Bucket |
| `docker15-legacy-dumps` | RW auf `backups` | einmalige .15-Dumps unter `docker15-legacy/` |
| `default access key` | **RWO** auf `backups` | beim Garage-Setup angelegt, kein bekannter Nutzer |
| `hass-backup` | RWO auf `hass-backups` | Home Assistant, schon ein eigener Bucket |
| `backup-ciso-assistant` | RW auf `backup-ciso-assistant` | neues Schema |

Klartext eines Secrets ansehen: `sops -d apps/base/roundcube/secret.sops.yaml`.

### Migrationsplan für die bestehenden Apps

Pro App ein eigener PR, damit ein Fehler nur eine App trifft:

1. Bucket und Key `backup-<app>` nach obigem Schema anlegen und per curl prüfen.
2. Ein PR ändert Secret und Ziel gleichzeitig:
   - CNPG: `destinationPath: s3://backup-<app>/cnpg/`. Der neue Pfad ist leer,
     deshalb schlägt `barman-cloud-check-wal-archive` nicht an.
   - MariaDB: `bucket: backup-<app>`, `prefix: mariadb` (WordPress:
     `mariadb-wordpress-N` bleibt je Instanz als Prefix). Das Feld ist auf dem
     bestehenden Backup-CR **immutable**: nach dem Merge das CR löschen,
     ArgoCD legt es neu an.
3. Nach dem Sync sofort ein Base-Backup anstoßen (siehe „manuelles
   Base-Backup“) und `ContinuousArchiving=True` sowie Objekte im neuen Bucket
   prüfen. Erst dann die nächste App angehen.
4. Der alte Prefix unter `backups/` bleibt 30 Tage als PITR-Fallback liegen. Ein
   Restore von dort braucht den alten Key `cnpg-backups`.

Reihenfolge nach Risiko: mastodon (kein aktiver DB-Pod) → matomo → kimai →
wordpress-1/-2/-3 → forgejo → paperless → mailman → roundcube; dann crowdsec
und expense (nur Bucket-Umzug, Key neu nach Schema).

Abschluss, frühestens 30 Tage nach der letzten Umstellung und nach je einem
**echten Restore-Test** aus einem neuen Bucket:

- Die alten Prefixe `cnpg-*`/`mariadb-*` in `backups` löschen.
- Die Keys `cnpg-backups`, `cnpg-crowdsec` und `cnpg-expense` mit
  `garage bucket deny` entziehen und dann `garage key delete`.
- `default access key`: Owner-Recht auf `backups` entziehen, danach löschen.
- `docker15-legacy/`: entweder in einen eigenen Bucket umziehen oder nach
  Ablauf der .15-Karenz löschen. Danach ist `backups` leer und kann weg.
- Buckets und Keys im Garage-Setup-Repo (`cfgmgmt01:/root/ansible/garage-s3`,
  bisher ohne Git) als idempotente Tasks abbilden. Derzeit ist alles Handarbeit.

## Konfiguration (GitOps)

Je App in `apps/base/<app>/database.yaml` unter `spec.backup.barmanObjectStore`
(WAL-Ziel + Credentials) und die `ScheduledBackup` in `apps/base/<app>/backup.yaml`
(Base-Backup-Zeitplan), in `kustomization.yaml` als `- backup.yaml` aktiviert.

> ⚠️ Reihenfolge-Falle: barmanObjectStore NIE mit unerreichbarem/falschem S3
> aktiviert lassen — CNPG kann dann keine WALs archivieren, kein WAL-Recycling,
> die PVC läuft voll und Postgres crasht (so passiert am 12.07. mit roundcube-pg).

## Backups prüfen

```bash
export KUBECONFIG=~/ansible/infrastructure/tofu/talos-cluster/envs/kellerIO/kubeconfig

# ScheduledBackups + letzte Backups
kubectl get scheduledbackup -A
kubectl get backup -A            # PHASE=completed erwartet

# Objekte im Bucket (aus einem Cluster-Pod oder von cfgmgmt01):
docker exec $(docker ps -qf name=garage) /garage bucket info backups   # auf .21
# oder per aws-cli mit dem cnpg-backups-Key:
aws --endpoint-url http://192.168.23.21:3900 --region garage-potsdam \
  s3 ls s3://backups/cnpg-roundcube/ --recursive
```

Ein manuelles Base-Backup anstoßen:
```bash
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: manual-$(date +%s), namespace: roundcube }
spec: { cluster: { name: roundcube-pg } }
EOF
```

## Restore (Point-in-Time / Disaster Recovery)

CNPG restauriert NICHT in-place. Man legt einen **neuen** Cluster an, der aus dem
Object-Store bootstrappt. Beispiel roundcube (Namespace roundcube):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: roundcube-pg-restore
  namespace: roundcube
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:16.6   # MUSS zur Major-Version passen
  storage: { size: 5Gi, storageClass: ceph-rbd }
  bootstrap:
    recovery:
      source: roundcube-quelle
      # Optional PITR statt neuestem Stand:
      # recoveryTarget: { targetTime: "2026-07-13 10:00:00+00" }
  externalClusters:
    - name: roundcube-quelle
      barmanObjectStore:
        destinationPath: s3://backups/cnpg-roundcube/
        # Erforderlich, wenn der Restore-Cluster anders als die Quelle heißt.
        serverName: roundcube-pg
        endpointURL: http://192.168.23.21:3900
        s3Credentials:
          accessKeyId: { name: roundcube-backup-s3, key: ACCESS_KEY_ID }
          secretAccessKey: { name: roundcube-backup-s3, key: SECRET_ACCESS_KEY }
        wal: { compression: gzip }
        data: { compression: gzip }
```

Ablauf:
1. Manifest anwenden, `kubectl get cluster -n roundcube -w` bis der Restore-Cluster
   `Cluster in healthy state` meldet (Recovery-Logs: `kubectl logs job/roundcube-pg-restore-1-full-recovery-...`).
2. Daten prüfen (Tabellen/Zeilen zählen).
3. Cutover: App auf den neuen Cluster zeigen lassen. Entweder den DB-Host in der
   App auf `roundcube-pg-restore-rw` umstellen, ODER den alten Cluster löschen und
   den Restore-Cluster in `database.yaml` auf `roundcube-pg` umbenennen und via
   GitOps übernehmen (Downtime einplanen).
4. Restore-Cluster/altes Objekt-Store-Ziel aufräumen.

> Voraussetzung: der Restore-Cluster braucht dieselbe Postgres-Major-Version wie
> das Backup (`imageName`), sonst verweigert CNPG den Recovery.

---

# MariaDB-Backup & Restore (mariadb-operator → Garage-S3)

Für die MariaDB-Apps (**kimai**, **wordpress-1/2/3**) gibt es kein barman —
stattdessen der native `Backup`-CRD des mariadb-operators (logischer
`mariadb-dump`, geplant).

```
MariaDB (kimai-mariadb, wordpress-mariadb ×3)
  └─ Backup-CR (schedule 0 2 * * *)  ──►  s3://backups/mariadb-<app>/  @ Garage
```

- **Prefixe:** `mariadb-kimai`, `mariadb-wordpress-1`, `-2`, `-3`. Bei WordPress
  wird der Prefix PRO Instanz im Overlay gepatcht (`apps/overlays/main/wordpress-N/`),
  sonst schreiben alle drei in denselben Ordner.
- **Format:** `backup.<timestamp>.gzip.sql` (ein logischer Dump je Lauf).
- **Retention:** 30 Tage (`maxRetention: 720h`). **Zeitplan:** täglich 02:00.
- **Config:** `apps/base/<app>/backup.yaml`. Secrets: `<app>-backup-s3` (bisher derselbe
  Garage-Key wie CNPG, Umstellung siehe Abschnitt Secrets). Endpoint OHNE Schema (`192.168.23.21:3900`), `tls.enabled: false`.

> ⚠️ `spec.storage.s3.bucket` und `.endpoint` sind auf einem bestehenden Backup-CR
> **immutable**. Ändert man das Ziel, muss das alte CR erst gelöscht werden
> (`kubectl delete backup.k8s.mariadb.com <name> -n <ns>`), dann re-sync.

## MariaDB-Backups prüfen

```bash
kubectl get cronjob -A | grep -E 'kimai-mariadb|wordpress-mariadb'   # SCHEDULE aktiv?
kubectl get backup.k8s.mariadb.com -A                                 # CRs
# Dumps im Bucket:
aws --endpoint-url http://192.168.23.21:3900 --region garage-potsdam \
  s3 ls s3://backups/mariadb-kimai/
```

Sofortiges Test-Backup (einmalig, ohne schedule):
```bash
kubectl apply -f - <<'EOF'
apiVersion: k8s.mariadb.com/v1alpha1
kind: Backup
metadata: { name: adhoc, namespace: kimai }
spec:
  mariaDbRef: { name: kimai-mariadb }
  compression: gzip
  storage:
    s3:
      bucket: backups
      prefix: mariadb-kimai
      endpoint: 192.168.23.21:3900
      region: garage-potsdam
      accessKeyIdSecretKeyRef: { name: kimai-backup-s3, key: ACCESS_KEY_ID }
      secretAccessKeySecretKeyRef: { name: kimai-backup-s3, key: SECRET_ACCESS_KEY }
      tls: { enabled: false }
EOF
kubectl get backup.k8s.mariadb.com adhoc -n kimai -o jsonpath='{.status.conditions[0]}'
```

## MariaDB-Restore

Über den `Restore`-CRD des Operators, der aus dem S3-Ziel in die (laufende)
MariaDB zurückspielt. **Achtung: überschreibt die Ziel-Datenbank.**

```yaml
apiVersion: k8s.mariadb.com/v1alpha1
kind: Restore
metadata:
  name: kimai-restore
  namespace: kimai
spec:
  mariaDbRef:
    name: kimai-mariadb          # Ziel-Instanz (muss laufen)
  # targetRecoveryTime: "2026-07-14T02:00:00Z"  # optional: nächstgelegener Dump
  s3:
    bucket: backups
    prefix: mariadb-kimai
    endpoint: 192.168.23.21:3900
    region: garage-potsdam
    accessKeyIdSecretKeyRef: { name: kimai-backup-s3, key: ACCESS_KEY_ID }
    secretAccessKeySecretKeyRef: { name: kimai-backup-s3, key: SECRET_ACCESS_KEY }
    tls: { enabled: false }
```

Ablauf: Manifest anwenden, `kubectl get restore -n kimai -w` bis
`Complete=True`; der Operator startet einen Job, der den jüngsten (bzw. den zu
`targetRecoveryTime` passenden) Dump einliest. Danach App-Pod ggf. neu starten.

WordPress analog mit `wordpress-mariadb` / `wordpress-backup-s3` und dem
Instanz-Prefix (`mariadb-wordpress-1` etc.) im jeweiligen Namespace.

---

## Bekannte Grenzen / offen

- Der `cnpg-backups`-Garage-Key hat **RWO** auf den gesamten `backups`-Bucket
  (alle App-Prefixe, CNPG + MariaDB). Umstellung auf je einen Bucket und Key pro
  App: siehe Abschnitt Secrets.
- MariaDB = nur logische Dumps (kein PITR). Für PITR wäre der `PhysicalBackup`-CRD
  + Binlog nötig.
- Restore je einmal echt testen (CNPG **und** MariaDB) → nach dem ersten grünen
  geplanten Backup einplanen.
