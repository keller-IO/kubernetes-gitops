# Mastodon-Migration nach Kubernetes

Migration der produktiven Instanz `jit.social` von `192.168.2.233` in den
Talos/Kubernetes-Cluster. Die Föderationsdomain wird nicht geändert.

## Erfasster Ausgangszustand

Stand: 28.07.2026

| Komponente | Altserver |
|---|---|
| Mastodon | 4.5.9, Source-Installation unter `/home/mastodon/live` |
| Domain | `LOCAL_DOMAIN=jit.social` |
| PostgreSQL | 16, `mastodon_production`, 20 GB |
| Daten | 321.503 Accounts, davon 64 lokal; 9.721.767 Statuses |
| Redis | 66 MB; 101 geplante Jobs, 9 Retries, 2.950 Dead Jobs |
| Elasticsearch | aktiv, 2,1 GB |
| Medien | lokales `public/system`; 902 lokale Attachments mit 494 MB Originalen |
| Remote-Medien | 1.642.227 Attachments mit etwa 110 GB Originalen |
| Public Routing | Cloudflare; Origin auf dem Altserver ist HTTP-only |

Der Root-Datenträger des Altservers ist zu 99 Prozent belegt. Neue Dumps dürfen
nicht dort abgelegt werden. Der separate Datenträger unter
`/home/mastodon/live/public` hatte bei der Bestandsaufnahme ausreichend freien
Platz, ersetzt aber kein Offsite-Backup.

## Phase 1-3: vorbereiteter GitOps-Stand

Der Stand in `apps/base/mastodon/` ist absichtlich nicht öffentlich nutzbar:

- Mastodon Web, Streaming und Sidekiq haben jeweils 0 Replikate.
- Der Ingress ist deaktiviert.
- `createAdmin`, `dbPrepare`, `dbMigrate` und `deploySearch` sind deaktiviert.
- Die trotzdem vom Chart erzeugten Predeploy-Hook-Hilfsressourcen werden per
  Kustomize gelöscht. Vor einer späteren kontrollierten Hook-Aktivierung müssen
  diese Delete-Patches wieder entfernt werden.
- Web- und Streaming-Images sind auf 4.5.9 gepinnt. Migration und Upgrade werden
  nicht miteinander vermischt.
- `LOCAL_DOMAIN` und der spätere Ingress-Host sind `jit.social`.
- Elasticsearch bleibt vorerst deaktiviert und ist ein Cutover-Blocker, solange
  der Funktionsverlust nicht ausdrücklich akzeptiert wurde.

Ein ArgoCD-Sync erzeugt die benötigten Secrets, ConfigMaps, Services,
ServiceAccounts, CNPG-/Backup-Ressourcen, den Valkey-PVC sowie ausschließlich
inaktive App-/Cache-Workloads. Er darf weder ein Datenbankschema initialisieren
noch einen öffentlich erreichbaren zweiten Mastodon-Server starten.

## Secrets

Folgende produktive Werte wurden direkt vom Altserver nach
`apps/base/mastodon/secret.sops.yaml` übernommen und anschließend per
Wertevergleich verifiziert:

- `SECRET_KEY_BASE`
- `OTP_SECRET`
- `VAPID_PRIVATE_KEY` und `VAPID_PUBLIC_KEY`
- alle drei `ACTIVE_RECORD_ENCRYPTION_*`-Schlüssel
- SMTP-Benutzer und SMTP-Passwort

`OTP_SECRET` bleibt als `otp-secret` archiviert. Das Chart injiziert diesen Wert
nicht mehr in die Pods; die alte OTP-Migration ist auf 4.5.9 bereits gelaufen.
Vor dem Cutover muss der Login des vorhandenen 2FA-Kontos getestet werden.

Das CNPG- und das Valkey-Passwort wurden neu zufällig erzeugt. Für den noch
anzulegenden Ceph-RGW-Benutzer `mastodon` wurden dedizierte Zugangsdaten im
Secret `mastodon-s3` erzeugt. Diese Zugangsdaten sind serverseitig noch nicht
aktiv, bis Benutzer und Bucket auf dem externen Ceph-RGW angelegt wurden.

Klartextwerte dürfen weder in Logs noch in dieses Runbook geschrieben werden.
Prüfen, dass keine Platzhalter verblieben sind:

```bash
just secrets-check
sops filestatus apps/base/mastodon/secret.sops.yaml
```

## Ziel-Storage

### PostgreSQL

`mastodon-pg` startet für den logischen Restore mit einer Instanz:

- PostgreSQL 16.14, Image und Digest gepinnt
- 64-GiB-Ceph-RBD-PVC
- Datenbank `mastodon`, Owner `mastodon`
- kontinuierliches WAL-Archiv und tägliches Base-Backup nach Garage-S3

Nach dem Restore auf drei Instanzen skalieren und erst weiterarbeiten, wenn CNPG
alle Replikate als gesund meldet. Der Quell-Dump aus `mastodon_production` wird
logisch in die Zieldatenbank `mastodon` restauriert.

### Valkey

`mastodon-valkey-data` ist ein separat provisionierter 2-GiB-Ceph-RBD-PVC. Das
StatefulSet bleibt bei 0 Replikaten, damit kein leerer AOF-Datenbestand vor dem
Restore erzeugt wird. Das reicht für den aktuell 66 MB großen Redis-Datenbestand.
Das finale `dump.rdb` wird im Wartungsfenster nach `redis-cli SAVE` auf den PVC
übernommen. Erst danach wird Valkey zunächst mit `appendonly no` und Auth über
`mastodon-redis` auf eine Replik skaliert. Nach Prüfung von Schlüsselanzahl,
Queues und geplanten Jobs wird AOF auf der laufenden, noch isolierten Instanz mit
`CONFIG SET appendonly yes` aktiviert. Erst wenn `INFO persistence` einen
erfolgreichen AOF-Rewrite meldet, wird `appendonly yes` per GitOps festgeschrieben
und Mastodon gestartet. So kann ein leerer AOF den restaurierten RDB-Datenbestand
nicht überstimmen.

### Medien-S3

Der Cluster besitzt weder die `ObjectBucketClaim`-CRD noch eine
`ceph-bucket`-StorageClass. Medien-S3 wird deshalb über den vorhandenen externen
Ceph-RGW unter `https://s3.jit.services` bereitgestellt. Eine OBC-Ressource ist
bewusst nicht Teil des Manifests.

Der dedizierte RGW-Benutzer `mastodon` und der feste Bucket `jit-social-media`
existierten bei der Bestandsaufnahme noch nicht. Ein Ceph-Administrator legt
beide mit den bereits in `mastodon-s3` hinterlegten Access Keys an. Keine
existierenden, breiter berechtigten RGW-Benutzer wiederverwenden.

Der Ceph-Cluster meldete bei der Bestandsaufnahme `HEALTH_WARN` wegen langsamer
BlueStore-Operationen, wenig freiem Platz auf einem Monitor und kürzlich
abgestürzten Daemons. Vor Mediensync und Cutover muss der Storage-Zustand geprüft
und für ausreichend stabil befunden werden.

Vor dem ersten Mediensync müssen diese Punkte grün sein:

- RGW-Benutzer `mastodon` mit Zugriff nur auf `jit-social-media` vorhanden
- Secret `mastodon-s3` entspricht den RGW-Zugangsdaten
- Bucket `jit-social-media` vorhanden
- authentifizierter Put/Get/Delete-Test erfolgreich
- hochgeladene Objekte öffentlich lesbar, aber Bucket nicht auflistbar
- CORS erlaubt `GET` von `https://jit.social`
- Ceph-Kapazität für bereinigten Bestand und Wachstum bestätigt

Bestehende URLs unter `https://jit.social/system/...` müssen dauerhaft erhalten
bleiben. Die dafür nötige `/system`-Proxyroute und `S3_ALIAS_HOST` gehören zu
Phase 4 und sind noch nicht aktiviert.

## Nächste Schritte

1. Diesen Stand per PR mergen und den ArgoCD-Sync beobachten.
2. CNPG-Cluster und Valkey-PVC read-only prüfen.
3. Dedizierten Ceph-RGW-Benutzer und Bucket mit den SOPS-Zugangsdaten anlegen.
4. Vollständigen Restore mit einem Vorab-Dump proben und Dauer messen.
5. Remote-Mediencache kontrolliert bereinigen und ersten S3-Sync ausführen.
6. Elasticsearch im Cluster bereitstellen oder den temporären Funktionsverlust
   ausdrücklich akzeptieren.
7. Cutover-PR vorbereiten: Ingress und je eine Web-, Streaming- und
   Sidekiq-Replik aktivieren; automatische DB-Hooks bleiben zunächst aus.
8. Wartungsfenster und Rollback nach dem separaten Cutover-Plan durchführen.

Der Altserver bleibt bis nach Restore-Test und stabiler Betriebsphase erhalten.
Alt- und Zielinstanz dürfen niemals gleichzeitig schreibend aktiv sein.
