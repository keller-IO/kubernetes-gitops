# Runbook — Datenbank-Backup & Restore (CNPG → Garage-S3)

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

## Secrets

Pro App ein SOPS-Secret `<app>-backup-s3` (`apps/base/<app>/secret.sops.yaml`) mit
`ACCESS_KEY_ID` / `SECRET_ACCESS_KEY`. Alle nutzen denselben Garage-Key
`cnpg-backups` (Key-ID `GK4abeaff…`), der nur read/write auf den `backups`-Bucket
hat. Klartext ansehen: `sops -d apps/base/roundcube/secret.sops.yaml`.

Neuen/rotierten Key erzeugen (auf `192.168.23.21`):
```bash
G=$(docker ps -qf name=garage | head -1)
docker exec $G /garage key create cnpg-backups
docker exec $G /garage bucket allow --read --write backups --key cnpg-backups
# neuen Key in alle apps/base/*/secret.sops.yaml (backup-s3) eintragen + sops -e
```

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

## Bekannte Grenzen / offen

- MariaDB (kimai, 3× wordpress) hat KEIN S3-Backup — separater Job nötig
  (mariadb-operator `Backup`-CR oder mysqldump-CronJob nach Garage).
- Der `cnpg-backups`-Garage-Key hat Zugriff auf den gesamten `backups`-Bucket
  (alle App-Prefixe). Für strengere Trennung: pro App eigener Key/Bucket.
- Restore einmal echt getestet? → nach dem ersten grünen ScheduledBackup einplanen.
