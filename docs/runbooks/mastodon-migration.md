# Mastodon-Migration nach Kubernetes

Migration der produktiven Instanz `jit.social` von `mastodon02`
(`192.168.2.233`) in den kellerIO-Cluster. Die Föderationsdomain wird nicht
geändert.

## Erfasster Ausgangszustand

Stand: 22.09.2026 (Erstaufnahme 28.07.2026)

| Komponente | Altserver |
|---|---|
| Mastodon | **4.5.18**, Source-Installation unter `/home/mastodon/live` |
| Domain | `LOCAL_DOMAIN=jit.social` |
| PostgreSQL | 16.14, `mastodon_production`, 21 GB |
| Daten | 558 User (1 mit 2FA), 31 aktive im Monat; ca. 327.000 Accounts, 10,1 Mio. Statuses |
| Redis | 87 MB, 126.000 Keys (inkl. Dead-/Retry-Sets) |
| Elasticsearch | aktiv, Index `public_statuses` 1,8 GB, gesamt ca. 2,1 GB |
| Medien | lokales `public/system` auf eigenem Datenträger (302 GB belegt); lokale Attachments 713 MB, Remote-Cache **272 GB** |
| Medien-Retention | wöchentlicher Cron des Users `mastodon`: `tootctl media remove` und `tootctl preview_cards remove` |
| Public Routing | Cloudflare-Tunnel: `cloudflared` (Token-verwaltet) auf mastodon02 → nginx `:80` |
| SMTP | `mail.jit-creatives.de:587` |
| Host | 4 vCPU, 6,3 GiB RAM |

Der Root-Datenträger des Altservers ist zu 99 Prozent belegt (957 MB frei).
Dumps dürfen nicht dort abgelegt werden; Dumps direkt in den Cluster streamen.

## Getroffene Entscheidungen

- **Remote-Mediencache wird nicht migriert** (Entscheidung 22.09.2026).
  Übertragen wird nur `public/system` ohne `cache/`. Remote-Medien alter Posts
  fehlen danach wie nach einer regulären `tootctl media remove`-Retention; neue
  Remote-Inhalte werden normal gecacht.
- `mastodon-pg` läuft mit **einer Instanz** plus WAL-Archiv, wie alle anderen
  CNPG-Cluster. Drei Instanzen erst nach der Migration neu bewerten.
- **Medien-Retention muss im Ziel neu gebaut werden.** Chart 1.0.3 bringt
  keinen CronJob dafür mit; der wöchentliche Cron des Altservers hat im Ziel
  kein Gegenstück. Ohne Ersatz wächst der Remote-Cache im RGW unbegrenzt.
  Eigener CronJob spätestens mit dem Cutover-PR, sonst füllt er Ceph.
  **Schärfer parametrisieren als auf dem Altserver:** dessen Cron läuft zwar
  (zuletzt 13.09. und 20.09.), trotzdem liegen dort 514.064 Cache-Dateien älter
  als 30 Tage. Ursache sind die Defaults — `media remove` fasst ohne
  `--prune-profiles` die Avatare und Header entfernter Profile nicht an, und
  `preview_cards remove` löscht erst ab 180 Tagen. Empfehlung für den CronJob:
  `media remove --days 7 --prune-profiles`, `preview_cards remove --days 30`
  und periodisch `media remove-orphans`.
- Migration und Upgrade werden nicht vermischt: Images sind auf **4.5.18**
  gepinnt, identisch zur Bestandsinstanz. Chart 1.0.3 bringt appVersion 4.6.3
  mit; das Upgrade folgt separat nach stabiler Betriebsphase.

## Offene Entscheidungen

- ~~Volltextsuche~~ **entschieden am 23.09.2026:** Die Suche wird separat
  behandelt. Elasticsearch bleibt im Manifest deaktiviert, der Cutover läuft
  ohne Volltextsuche. Nachrüsten später per OpenSearch im Cluster und
  `tootctl search deploy`.
- **Eingangsweg nach dem Cutover:** Empfehlung: Cloudflare-Tunnel zunächst
  beibehalten und nur das Tunnel-Ziel auf den Ingress `192.168.2.246` umstellen
  (Rollback = Ziel zurückstellen, DNS unverändert). Vorher prüfen, dass der
  Ingress für Tunnel-Anfragen keine Redirect-Schleife erzeugt. Danach
  `cloudflared` in den Cluster holen oder wie die übrigen Dienste direkt über
  die UDM veröffentlichen.

## Phase 1: GitOps-Stand ohne Live-Wirkung

Der Stand in `apps/base/mastodon/` ist absichtlich nicht öffentlich nutzbar:

- Mastodon Web, Streaming, Sidekiq und Valkey haben jeweils 0 Replikate.
- Der Ingress ist deaktiviert.
- `createAdmin`, `dbPrepare`, `dbMigrate` und `deploySearch` sind deaktiviert.
- Die trotzdem vom Chart erzeugten Predeploy-Hook-Hilfsressourcen werden per
  Kustomize gelöscht. Vor einer späteren kontrollierten Hook-Aktivierung müssen
  diese Delete-Patches wieder entfernt werden.
- `LOCAL_DOMAIN` und der spätere Ingress-Host sind `jit.social`.

Zusätzlich ist die App in `clusters/main/appset-apps.yaml` per `exclude`
ausgeschlossen. **Das Entfernen dieses Excludes ist der Schalter**, der den
Stack erzeugt, denn alle Applications laufen mit Auto-Sync (prune + selfHeal).
Es geschieht in einem eigenen PR (Phase 3).

Ein Sync erzeugt dann Secrets, ConfigMaps, Services, ServiceAccounts, den
CNPG-Cluster mit Backup, den Valkey-PVC sowie ausschließlich inaktive App- und
Cache-Workloads. Er darf weder ein Datenbankschema initialisieren noch einen
öffentlich erreichbaren zweiten Mastodon-Server starten.

## Secrets

Folgende produktive Werte wurden am 28.07. direkt vom Altserver nach
`apps/base/mastodon/secret.sops.yaml` übernommen und per Wertevergleich
verifiziert:

- `SECRET_KEY_BASE`
- `OTP_SECRET`
- `VAPID_PRIVATE_KEY` und `VAPID_PUBLIC_KEY`
- alle drei `ACTIVE_RECORD_ENCRYPTION_*`-Schlüssel
- SMTP-Benutzer und SMTP-Passwort

Am 22.09. wurde die Datei für beide age-Empfänger neu verschlüsselt; das
Backup-Secret liegt seitdem getrennt in `backup-s3.sops.yaml` (Bucket und Key
`backup-mastodon`). Ein Hash-Vergleich bestätigte unveränderte Werte.

`OTP_SECRET` bleibt als `otp-secret` archiviert. Das Chart injiziert diesen Wert
nicht mehr in die Pods; die alte OTP-Migration ist bereits gelaufen. Vor dem
Cutover muss der Login des vorhandenen 2FA-Kontos getestet werden.

Das CNPG- und das Valkey-Passwort wurden neu zufällig erzeugt. Für den noch
anzulegenden Ceph-RGW-Benutzer `mastodon` liegen dedizierte Zugangsdaten im
Secret `mastodon-s3`.

Klartextwerte dürfen weder in Logs noch in dieses Runbook geschrieben werden.
Vor dem Cutover erneut per Hash gegen `.env.production` prüfen, ob sich
SMTP-Zugang oder Schlüssel seit Juli geändert haben.

```bash
just secrets-check
sops filestatus apps/base/mastodon/secret.sops.yaml
```

## Phase 2: Ziel-Storage

### Voraussetzung Ceph

Am 22.09.2026 meldete Ceph `HEALTH_ERR`: zwei OSDs mit langsamen
BlueStore-Operationen, eine OSD mit *stalled read* im BlueFS-DB-Device (alle PGs
`active+clean`, `MAX AVAIL` 1,1 TiB). Vor Restore-Probe und Cutover müssen diese
Befunde geklärt sein. Kein Restore auf RBD bei laufendem stalled read.

### PostgreSQL

`mastodon-pg`: PostgreSQL 16.14 (Image per Digest gepinnt), 64-GiB-Ceph-RBD-PVC,
Datenbank `mastodon` mit Owner `mastodon`, WAL-Archiv und Base-Backup nach
`s3://backup-mastodon/cnpg/` (Garage). Der Dump aus `mastodon_production` wird
logisch in `mastodon` restauriert.

### Valkey

`mastodon-valkey-data` ist ein separat provisionierter 2-GiB-Ceph-RBD-PVC. Das
StatefulSet bleibt bei 0 Replikaten, damit kein leerer AOF-Datenbestand vor dem
Restore erzeugt wird. Vor dem finalen `redis-cli SAVE` auf dem Altserver die
Dead- und Retry-Sets von Sidekiq bewerten und leeren.

Das finale `dump.rdb` wird im Wartungsfenster auf den PVC übernommen. Erst
danach wird Valkey mit `appendonly no` und Auth über `mastodon-redis` auf eine
Replik skaliert. Nach Prüfung von Schlüsselanzahl, Queues und geplanten Jobs
wird AOF auf der noch isolierten Instanz mit `CONFIG SET appendonly yes`
aktiviert. Erst wenn `INFO persistence` einen erfolgreichen AOF-Rewrite meldet,
wird `appendonly yes` per GitOps festgeschrieben und Mastodon gestartet.

### Medien-S3

Der Cluster besitzt weder die `ObjectBucketClaim`-CRD noch eine
`ceph-bucket`-StorageClass. Medien liegen deshalb im externen Ceph-RGW.

**⚠️ Der früher eingetragene Endpunkt `https://s3.jit.services` existiert
nicht.** Der Name fällt nur ins Wildcard-DNS auf `192.168.2.246`, wo nginx ihn
per SNI ablehnt (`unrecognized name`). Mastodon spricht den RGW stattdessen
intern über den Service `s3.legacy-proxy.svc.cluster.local:7480` an, hinter dem
alle drei RGW-Daemons (`192.168.2.6/.7/.8`) stehen. Aus dem Cluster mit HTTP 200
geprüft. `S3_ENDPOINT` bringt sein eigenes Schema mit, `S3_PROTOCOL` gilt nur
für die erzeugten Medien-URLs — interner HTTP-Zugriff und öffentliche
HTTPS-Links schließen sich also nicht aus
(siehe `config/initializers/paperclip.rb`).

**Erledigt am 23.09.2026:**

- RGW-Benutzer `mastodon` angelegt, mit den Schlüsseln aus `mastodon-s3`,
  `max_buckets=1` und `op_mask=read,write,delete`.
- Bucket `jit-social-media` angelegt, Owner `mastodon`, leer.
- Benutzer-Quota 100 GiB, aktiv. Ausgelegt auf lokale Medien plus den
  7-Tage-Remote-Cache; bei Bedarf mit `radosgw-admin quota set` anheben.
- CORS gesetzt: `GET` und `HEAD` von `https://jit.social`, `MaxAge` 3000.
- Abnahme bestanden: authentifiziertes PUT/GET/DELETE, anonymer GET auf ein
  `public-read`-Objekt (200), anonymer GET ohne ACL (403), anonymes Listing
  (403), Anlegen eines zweiten Buckets scheitert an `max_buckets`
  (`TooManyBuckets`). Alle Probeobjekte wurden wieder entfernt.

Sync-Umfang: `public/system` **ohne** `cache/` (ca. 1 GB). Erstsync vorab,
Delta-Sync im Wartungsfenster.

Bestehende URLs unter `https://jit.social/system/...` müssen erhalten bleiben.
`S3_ALIAS_HOST=jit.social/system` und die `/system`-Route im Ingress gehören
deshalb **in denselben Cutover-PR**; einzeln ausgerollt zeigen die Medien-URLs
ins Leere. Mit Alias-Host erzeugt Mastodon `:s3_alias_url`, also
`https://jit.social/system/<pfad>` ohne Bucket im Pfad — die Ingress-Route muss
das auf den Bucket-Pfad `/jit-social-media/` abbilden.

## Phase 3: Probe

1. Exclude in `clusters/main/appset-apps.yaml` per PR entfernen; Sync
   beobachten. Alle Workloads bleiben bei 0 Replikaten.
2. CNPG-Cluster, Backup-Status und Valkey-PVC prüfen.
3. Restore-Probe: `pg_dump -Fc` auf dem Altserver direkt per Pipe nach
   `pg_restore` im CNPG-Pod streamen, nicht auf die Root-Platte des
   Altservers. Dauer messen; sie bestimmt das Wartungsfenster.
4. Nur für den Test Web auf eine Replik skalieren, ohne Sidekiq und ohne
   Ingress, Zugriff per Port-Forward: Login, 2FA-Konto, lokale Medien,
   Timeline. Danach wieder auf 0. Sidekiq darf in der Probe nie laufen, sonst
   föderiert die Kopie.
5. SMTP vom Pod aus prüfen (Relay-Zugriff und SPF für den Cluster-Egress).

## Phase 4: Cutover

1. Altserver stoppen: `mastodon-sidekiq`, dann Web und Streaming.
2. Finaler Dump und Restore wie in der Probe; `redis-cli SAVE` und `dump.rdb`
   übernehmen; Valkey-Reihenfolge wie oben.
3. Delta-Sync der lokalen Medien.
4. Cutover-PR: Ingress sowie je eine Web-, Streaming- und Sidekiq-Replik
   aktivieren; automatische DB-Hooks bleiben aus.
5. Verkehr umschalten (siehe offene Entscheidung zum Eingangsweg).
6. Föderation, Push, Mail und Streaming testen; Gatus-Check für `jit.social`
   wieder aufnehmen.

Rollback: Tunnel-Ziel zurück auf den Altserver und dessen Dienste starten.
Sauber möglich, solange im Cluster noch nichts geschrieben wurde; danach nur per
Rück-Dump. Alt- und Zielinstanz dürfen niemals gleichzeitig schreibend aktiv
sein.

## Phase 5: Nacharbeit

- Altserver etwa zwei Wochen gestoppt, aber unverändert vorhalten.
- Medien-Retention im Cluster überwachen: erster CronJob-Lauf und
  RGW-Bucket-Wachstum prüfen.
- Restore-Test aus `backup-mastodon`.
- Danach mastodon02 stilllegen; Mastodon-Upgrade auf 4.6 separat.
