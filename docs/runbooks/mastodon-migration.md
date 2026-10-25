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
- **Physische statt logischer Migration** (Entscheidung 23.09.2026, gemessen):
  Der logische Weg (`pg_dump | pg_restore`, einfädig) brauchte **3 h 59 min**,
  weil 10,1 Mio. Zeilen eingefügt und 309 Indizes neu gebaut werden müssen. Die
  physische Kopie per `pg_basebackup` brauchte **31 min** — die Indizes kommen
  fertig mit. Ein Dump über S3 hätte nichts geändert: der Aufwand liegt im
  Restore, nicht im Transport. Seitdem folgt der Cluster mastodon02 als
  Replica-Cluster, der Cutover ist nur noch eine Promotion.
- **Medien-Retention muss im Ziel neu gebaut werden.** Chart 1.0.3 bringt
  keinen CronJob dafür mit; der wöchentliche Cron des Altservers hat im Ziel
  kein Gegenstück. Ohne Ersatz wächst der Remote-Cache im RGW unbegrenzt.
  Eigener CronJob spätestens mit dem Cutover-PR, sonst füllt er Ceph.
  **Umgesetzt (19.10.2026, Chart 1.2.5 bringt weiterhin keinen CronJob mit):**
  `apps/base/mastodon/media-retention.yaml` mit vier CronJobs
  (`mastodon-media-attachments-remove` täglich 01:00, `mastodon-media-remove`
  täglich 03:30, `mastodon-preview-cards-remove` täglich 04:10,
  `mastodon-media-remove-orphans` sonntags 04:30, Europe/Berlin). Der
  Anhänge-Job kam erst am 20.10.2026 dazu (siehe
  `docs/learnings/mastodon-remote-cache-nach-cutover.md`). Erster
  Lauf nach dem Cutover manuell beobachten (`kubectl create job --from=cronjob/…`),
  `remove-orphans` zuerst mit `--dry-run`.
  **Schärfer parametrisieren als auf dem Altserver:** dessen Cron läuft zwar
  (zuletzt 13.09. und 20.09.), trotzdem liegen dort 514.064 Cache-Dateien älter
  als 30 Tage. Ursache sind die Defaults — `media remove` fasst ohne
  `--prune-profiles` die Avatare und Header entfernter Profile nicht an, und
  `preview_cards remove` löscht erst ab 180 Tagen. Empfehlung für die CronJobs:
  `media remove --days 7` (Anhänge) **und getrennt davon**
  `media remove --days 7 --prune-profiles` (Profilbilder),
  `preview_cards remove --days 30` und periodisch `media remove-orphans`.
  ⚠️ `--prune-profiles` ersetzt den Anhänge-Lauf, statt ihn zu ergänzen: mit
  dem Flag bearbeitet tootctl nur Avatare und Header. Die ursprüngliche
  Empfehlung hier hatte nur diesen einen Aufruf, deshalb lief vom 19. bis
  20.10.2026 keine Anhang-Retention.
- Migration und Upgrade werden nicht vermischt: Images sind auf **4.5.18**
  gepinnt, identisch zur Bestandsinstanz. Chart 1.0.3 bringt appVersion 4.6.3
  mit; das Upgrade folgt separat nach stabiler Betriebsphase.

## Offene Entscheidungen

Keine mehr — beide sind entschieden:

- **Volltextsuche** (23.09.2026, geändert 19.10.2026): Der Cutover läuft ohne
  Volltextsuche. Nachgerüstet wird mit **Elasticsearch 8.19** (nicht OpenSearch):
  Mastodon ab 4.6 nutzt den elasticsearch-ruby-8.19-Client, der OpenSearch
  ablehnt. Umsetzung in drei PRs:
  1. **PR 1** (`apps/base/mastodon/search.yaml`, `search-network-policy.yaml`,
     Secret `mastodon-elasticsearch`): eigenständige Single-Node-Komponente
     `mastodon-search:9200`, Mastodon bleibt unverbunden (`elasticsearch.enabled: false`).
  2. **PR 2**: Anbinden (`elasticsearch.enabled: true`, `hostname: mastodon-search`,
     `tls: false`, `existingSecret: mastodon-elasticsearch`) und einmalig
     `tootctl search deploy` (Index aus Postgres aufbauen; Bestandsinstanz hatte
     ca. 2,1 GB Index). Vorher Ressourcenlage der Nodes prüfen.
  3. **PR 3**: Aufräumen/Beobachtung (Alerts auf Heap/Disk, ggf. Scrape,
     Sizing nachschärfen).
  - **Sizing:** Heap 2 GiB (`-Xms2g -Xmx2g`), Pod requests 500m/3Gi, Limit 4Gi
    (Rest für Page-Cache/Off-Heap), PVC 10Gi `ceph-rbd`; nicht auf `kellerio-wrk4`
    (8 GiB), bevorzugt nicht auf Nodes mit Mastodon web/sidekiq.
  - **`node.store.allow_mmap=false`:** Talos erlaubt kein `vm.max_map_count`-Tuning
    per Init-Container; ohne mmap entfällt die Vorgabe, kostet etwas Suchperformance.
  - **Read-only Root-FS:** Init-Container kopiert die Default-Config in ein emptyDir
    (ES schreibt dort `elasticsearch.keystore`); `logs` und `/tmp` ebenfalls emptyDir.
  - **Sicherheit:** `xpack.security` aus; Zugriff nur über CiliumNetworkPolicy
    (Ingress 9200 nur von Mastodon-Rails-Pods und dem `deploy-search`-Job).
  - **Backup-Ausnahme:** kein Garage-/S3-Backup; der Index ist jederzeit aus
    Postgres rekonstruierbar (`tootctl search deploy`), Postgres wird per CNPG gesichert.
  - Renovate bleibt per `packageRules` auf 8.19.x.
- **Eingangsweg** (23.09.2026): **direkt über die UDM**, kein Cloudflare-Proxy
  und kein Tunnel. Cloudflare bleibt reiner DNS-Anbieter.

### Warum direkt statt Tunnel

Die UDM leitet 80 und 443 auf **beiden** WAN-Strecken (`ppp0` und `eth7`)
bereits nach `192.168.2.246`. `jit.cloud`, `auth.savar.de`, `office.savar.de`
und `status.jit-creatives.de` zeigen direkt auf `87.191.135.42`; `jit.social`
war der letzte Dienst hinter Cloudflare.

Die Vorteile des Tunnels greifen hier nicht:

- *Origin-IP verstecken* ist gegenstandslos, solange dieselbe Adresse an sechs
  anderen Stellen öffentlich steht.
- *Unabhängigkeit vom WAN-IP-Wechsel* ebenso: die gesamte Umgebung hängt
  bereits an dieser Adresse, mit TTLs im Stundenbereich.
- *CDN-Caching für Medien* wäre das einzige echte Argument. Bei 31 aktiven
  Nutzern ist das Volumen gering, und der große Cache-Bestand waren eingehende
  Remote-Medien, die niemand von außen abruft. Falls es doch klemmt, gibt es
  zwei Hebel ohne Rückkehr zum Tunnel: Medien über einen eigenen öffentlichen
  RGW-Namen ausliefern, oder `jit.social` auf die InternetNord-Adresse
  `185.89.37.138` legen und den DSL-Upstream unbelastet lassen.

Dagegen kostet der Tunnel: `cloudflared` läuft auf genau dem Server, den wir
abschalten wollen, und müsste samt Token in den Cluster umziehen. Cloudflares
Bot-Schutz sitzt zwischen der Föderation und uns — ActivityPub-Abrufe fremder
Instanzen sind genau die Art maschineller Requests, die solche Regeln abweisen,
und der Fehler äußert sich als „Posts kommen bei manchen Instanzen nicht an".
Und alle Client-IPs kämen als Cloudflare-Adressen an, was für Rate-Limits und
CrowdSec zusätzliche Real-IP-Konfiguration nötig machte.

**⚠️ Die TTL lässt sich nicht vorab senken.** Solange der Proxy aktiv ist,
erzwingt Cloudflare TTL „Auto" und liefert die Anycast-Adressen mit fest 300
Sekunden aus (am 24.09.2026 direkt an `athena.ns.cloudflare.com` nachgemessen).
TTL 60 wird erst in dem Moment gesetzt, in dem der Eintrag auf grau umgestellt
und auf `87.191.135.42` gezeigt wird — danach ist der Rollback schnell.

Für die bis zu 5 Minuten, in denen Resolver noch die alte, proxied Antwort
halten, wird **mastodon02 kurzzeitig zum Reverse Proxy**: sein nginx bekommt
statt des lokalen Mastodon `proxy_pass http://192.168.2.246;` mit
`Host: jit.social`. Dann führen beide Wege — der alte über Cloudflare und der
neue direkt — auf dieselbe neue Instanz, und der DNS-Wechsel wird unkritisch.
Der Tunnel bleibt dabei bis zuletzt in Betrieb.

**Genau deshalb bleibt `ssl-redirect` in dieser Phase `false`:** Über den Tunnel
kommt der Verkehr als HTTP am Ingress an. Mit `true` antwortet nginx dort 301
auf https, der Client geht wieder über Cloudflare — eine Endlosschleife, die
gleiche Falle wie seinerzeit über `.15` (#169). Erst wenn DNS umgestellt und
`cloudflared` gestoppt ist, wird `ssl-redirect` auf `true` gezogen.

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

Nachgeprüft am 23.09.2026 — **kein Blocker mehr**, die Einschätzung vom 22.09.
war zu pauschal:

- Das `HEALTH_ERR` stammt **nicht** vom Storage, sondern von zwei
  Auth-Meldungen (`AUTH_INSECURE_SERVICE_KEY_TYPE`,
  `AUTH_INSECURE_SERVICE_TICKETS`) zu unsicheren cephx-Schlüsseltypen. Das ist
  eine Konfigurationsaltlast, kein Datenrisiko, und separat zu behandeln.
- Slow-Ops (`osd.0`, `osd.1`, `osd.6`) und der stalled read im DB-Device
  (`osd.1`) sind nur `[WRN]`. Der Alarm hält bei
  `bluestore_slow_ops_warn_threshold=1` und
  `bluestore_slow_ops_warn_lifetime=86400` schon nach **einer einzigen**
  langsamen Operation 24 Stunden an.
- `dump_historic_slow_ops` war auf allen drei OSDs leer; das jüngste Ereignis
  war ein einzelner 5,07-Sekunden-Commit auf `osd.0` am 23.09. um 06:22.
- SMART aller drei Datenträger (GIGASTONE 1 TB auf cloud65, Netac 2 TB auf
  cloud62, Crucial MX500 4 TB auf pve): `PASSED`, keine CRC-Fehler, eine
  einzige reallozierte Sektorangabe auf dem Netac. Es sind
  Consumer-SSD-Latenzspitzen unter Last, kein sterbendes Gerät.
- Alle PGs `active+clean`, `MAX AVAIL` 1,1 TiB.

Vor dem Cutover erneut `ceph -s` prüfen. Treten Slow-Ops **während** des
Restores gehäuft auf, ist das ein Grund zum Abbruch, nicht die stehende
Warnung an sich.

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

Sync-Umfang: `public/system` **ohne** `cache/`.

**Erstsync erledigt am 24.09.2026:** 2425 Objekte, 685 MiB, 0 Fehler, 1 min 13 s.
Werkzeug ist `rclone` (auf mastodon02 aus dem Debian-Paket nachinstalliert, mit
dem Altserver zu entfernen). Zugangsdaten kommen aus SOPS und stehen nur in der
Umgebung, nie in der Kommandozeile:

```bash
export RCLONE_CONFIG_RGW_TYPE=s3 RCLONE_CONFIG_RGW_PROVIDER=Ceph \
  RCLONE_CONFIG_RGW_ENDPOINT=http://192.168.2.7:7480 RCLONE_CONFIG_RGW_REGION=default \
  RCLONE_CONFIG_RGW_FORCE_PATH_STYLE=true RCLONE_CONFIG_RGW_NO_CHECK_BUCKET=true \
  RCLONE_CONFIG_RGW_ACL=public-read
rclone copy /home/mastodon/live/public/system rgw:jit-social-media \
  --exclude "cache/**" --transfers 8 --checkers 16 \
  --header-upload "Cache-Control: public, max-age=315576000, immutable"
```

`--s3-acl public-read` und der `Cache-Control`-Header sind Pflicht: ohne sie
liefert der RGW anonym 403 beziehungsweise die Objekte unterscheiden sich von
denen, die Mastodon selbst hochlädt. `NO_CHECK_BUCKET` ist nötig, weil der Key
wegen `max_buckets=1` kein CreateBucket ausführen darf.

Stichprobe bestanden: ein Objekt anonym mit HTTP 200 geladen, SHA256 und Größe
identisch zur Quelle, `Cache-Control` und `Content-Type` korrekt gesetzt.

**Delta-Sync im Wartungsfenster** mit demselben Befehl — er überträgt dann nur,
was seit dem 24.09. hinzugekommen ist.

Bestehende URLs unter `https://jit.social/system/...` müssen erhalten bleiben.
`S3_ALIAS_HOST=jit.social/system` und die `/system`-Route im Ingress gehören
deshalb **in denselben Cutover-PR**; einzeln ausgerollt zeigen die Medien-URLs
ins Leere. Mit Alias-Host erzeugt Mastodon `:s3_alias_url`, also
`https://jit.social/system/<pfad>` ohne Bucket im Pfad — die Ingress-Route muss
das auf den Bucket-Pfad `/jit-social-media/` abbilden.

## Phase 3: Replik aufgebaut (erledigt 23.09.2026)

1. ✅ Exclude aus `clusters/main/appset-apps.yaml` entfernt (#207); Sync legte
   Secrets, Services, CNPG-Cluster und PVCs an, alle Workloads auf 0.
2. ✅ Quelle vorbereitet: Rolle `streaming_replica` (REPLICATION, LOGIN),
   `pg_hba`-Einträge **nur** für die acht kellerIO-Nodes `192.168.2.81`–`.88`
   als `hostssl` mit `scram-sha-256`, `listen_addresses` per Drop-in
   `conf.d/10-kellerio-migration.conf`. Sicherung: `pg_hba.conf.bak-20260923`.
   Für `listen_addresses` war ein PostgreSQL-Neustart nötig; Mastodon kam
   danach sauber zurück (HTTP 200, eine Fehlerzeile im Log).
   **Beides nach der Migration zurückbauen.**
3. ✅ Verbindung aus einem Cluster-Pod geprüft: normale Verbindung mit TLS und
   Replikationsverbindung (`IDENTIFY_SYSTEM`) erfolgreich.
4. ✅ Cluster per `bootstrap.pg_basebackup` neu aufgebaut: **31 min 3 s** für
   21 GB. Danach `in_recovery=true`, WAL-Receiver `streaming`, empfangene und
   angewendete LSN identisch, 309 Indizes vorhanden.

**Reihenfolge-Falle:** Ein bereits bestehender Cluster übernimmt weder einen
geänderten `bootstrap`-Abschnitt noch `replica.enabled`. Er muss gelöscht und
neu angelegt werden. ArgoCD legt ihn dabei sofort aus seiner **zwischen-
gespeicherten** Revision neu an — erst `argocd.argoproj.io/refresh=hard`
setzen, warten bis die Application auf dem neuen Commit steht, dann löschen.

## Re-Seed des Replikats

Symptom: `mastodon-pg` steht still (replay LSN friert ein), im Pod-Log
`requested WAL segment ... has already been removed`. So geschehen am
07.10.2026 nach den Stromarbeiten: Die Quelle hatte `wal_keep_size = 0`, keinen
Replikationsslot und kein Archiv, also fehlte das WAL, sobald das Replikat
laenger als wenige Minuten weg war. Eine Reparatur ohne neues Basebackup gibt es
nicht. Begleitfehler: `role "cnpg_metrics_exporter" does not exist` — die Rolle
(`LOGIN`, `pg_monitor`) muss auf der Quelle existieren, weil sie physisch
mitrepliziert wird.

Ablauf (18.10.2026, ca. 30 min fuer 21 GB):

1. Quelle pruefen: `show wal_keep_size` muss `8GB` sein (Drop-in
   `conf.d/10-kellerio-migration.conf` auf mastodon02, ca. 1,3 GiB WAL/Tag ->
   rund sechs Tage Puffer); Rolle `cnpg_metrics_exporter` vorhanden.
2. Neuen `serverName` in `spec.backup.barmanObjectStore` setzen (`-r2`, `-r3`, ...),
   sonst scheitert die WAL-Archivierung des neuen Clusters mit "Expected empty
   archive". Per PR mergen.
3. `argocd.argoproj.io/refresh=hard` auf die Application setzen und warten, bis
   sie auf dem Merge-Commit steht (Reihenfolge-Falle aus Phase 3).
4. `kubectl -n mastodon delete cluster mastodon-pg`; ArgoCD legt den Cluster neu
   an, Job `mastodon-pg-1-pgbasebackup` zieht die Daten.
5. Pruefen: `pg_is_in_recovery()` = t, WAL-Receiver `streaming`, Abstand zu
   `pg_current_wal_lsn()` der Quelle klein, `pg_stat_archiver` ohne juengeren
   Fehler, Condition `ContinuousArchiving=True`, Metrik
   `cnpg_pg_replication_lag` auf Port 9187. Danach On-Demand-Backup anlegen.
6. Nacharbeit: alten S3-Prefix `cnpg/mastodon-pg/` loeschen, sobald das neue
   Base-Backup `completed` ist.

## Phase 4: Cutover

Vorbedingung: Replikation ist aktuell (`pg_last_wal_receive_lsn()` folgt der
Quelle, Lag im Sekundenbereich).

1. Mastodon auf mastodon02 stoppen: `mastodon-sidekiq`, dann Web und Streaming.
   **Erst danach** ist die Quelle schreibfrei.
2. Warten, bis die Replik den letzten WAL angewendet hat: `sent_lsn` auf der
   Quelle gleich `pg_last_wal_replay_lsn()` im Ziel.
3. `redis-cli SAVE` auf der Quelle, `dump.rdb` auf den Valkey-PVC übernehmen,
   Valkey nach der Reihenfolge aus Phase 2 starten.
4. Delta-Sync der lokalen Medien (`public/system` ohne `cache/`).
5. **Promotion:** `replica.enabled: false` per PR. CNPG beendet den
   Recovery-Modus und macht den Cluster schreibfähig.
   Kein `ALTER ROLE` und kein Umbenennen nötig: Die App spricht
   `mastodon_production` an, und `mastodon-db-app` trägt das Kennwort der
   Quelle.
6. Cutover-PR: Ingress sowie je eine Web-, Streaming- und Sidekiq-Replik
   aktivieren, `S3_ALIAS_HOST` und die `/system`-Route gemeinsam scharfstellen;
   automatische DB-Hooks bleiben aus.
   **Drei Fallen, am 19.10.2026 vorab gefunden:**
   - Die Rolle `mastodon` hat auf der Quelle **kein Kennwort** (peer-Auth über den
     Socket). `mastodon-db-app` trägt zwar `DB_PASS` der `.env.production`, in der
     DB gesetzt ist es aber nirgends: Login schlägt mit `password authentication
     failed` fehl. Der Promotions-PR (#300) setzt es per `spec.managed.roles`.
   - `letsencrypt-prod` hat für `jit.social` keinen Solver; deshalb eigener Issuer
     `mastodon-letsencrypt` (HTTP-01, edit-in-place) in `issuer.yaml`.
   - ArgoCD schließt **EndpointSlice** aus: die Slice `rgw` aus
     `media-backend.yaml` vor dem Cutover-Merge einmalig von Hand anwenden, sonst
     liefert `/system/` 502 bei grüner App.
7. Verkehr umschalten, in dieser Reihenfolge:
   1. nginx auf mastodon02 auf `proxy_pass http://192.168.2.246;` mit
      `Host: jit.social` umstellen und neu laden. Ab hier bedient auch der
      Cloudflare-Weg die neue Instanz; prüfen mit einem Abruf über
      `https://jit.social`.
   2. Zertifikat prüfen (`kubectl get certificate -n mastodon`). Die
      HTTP-01-Challenge läuft in dieser Phase ebenfalls über den Tunnel und
      den temporären Proxy.
   3. In Cloudflare den Proxy abschalten (graue Wolke), A-Record auf
      `87.191.135.42`, **TTL 60**.
   4. Warten, bis die direkte Auflösung greift, dann `cloudflared` auf
      mastodon02 stoppen und deaktivieren.
   5. Erst jetzt `ssl-redirect` per Folge-PR auf `true`.
8. Föderation, Push, Mail und Streaming testen; Gatus-Check für `jit.social`
   wieder aufnehmen.

Rollback: Tunnel-Ziel zurück auf den Altserver und dessen Dienste starten.
Sauber möglich, solange im Cluster noch nichts geschrieben wurde; nach der
Promotion und ersten Schreibzugriffen nur noch per Rück-Dump. Alt- und
Zielinstanz dürfen niemals gleichzeitig schreibend aktiv sein.

## Phase 5: Nacharbeit

- Altserver etwa zwei Wochen gestoppt, aber unverändert vorhalten.
- Medien-Retention im Cluster überwachen: erster CronJob-Lauf und
  RGW-Bucket-Wachstum prüfen.
- Restore-Test aus `backup-mastodon`.
- Danach mastodon02 stilllegen; Mastodon-Upgrade auf 4.6 separat (siehe
  „Versions-Upgrades“).
  **Stand 21.10.2026:** mastodon02 ist ausgeschaltet. Web, Streaming und
  Sidekiq laufen seitdem redundant (#339, [mastodon-betrieb.md](mastodon-betrieb.md)).

## Versions-Upgrades

Entscheidung 21.10.2026: 4.5 → **4.6** → 4.7, nicht direkt auf 4.7. Die langen
Migrationen von 4.7.0 laufen laut Release Notes nur von 4.6 aus ohne Downtime
(Pre-Migrationen, Pods tauschen, Post-Migrationen). Renovate ist per
`allowedVersions` in `renovate.json` auf `v4.7.x` begrenzt. Eine neue
Minor-Version vorher am Restore-Klon messen (unten).

**Stand 25.10.2026:** 4.7.3 läuft seit 08:06Z (#386), ohne Ausfall und ohne
Lock-Timeout. PITR-Ziel davor: 2026-10-25T07:37:57Z. Messwerte unter
„4.6.9 → 4.7.3“.

**Stand 23.10.2026:** 4.6.9 läuft seit 09:03Z (#338). Backup davor:
`mastodon-pg-pre-4-6-20261022`, PITR-Ziel 2026-10-23T08:49:37Z. Beim
PreSync-Hook fiel die Seite fünf Minuten aus
([Learning](../learnings/mastodon-migration-lock-stau.md)).

Migrationen laufen als ArgoCD-Hooks aus `apps/base/mastodon/db-migrate.yaml`:
`mastodon-db-migrate-pre` (PreSync, `SKIP_POST_DEPLOYMENT_MIGRATIONS=true`) vor
dem Image-Wechsel, `mastodon-db-migrate-post` (PostSync) danach. Ihr Image ist
wie die Retention-CronJobs an `values.yaml` `image.tag` gekoppelt; Renovate hebt
alle Stellen gemeinsam an. Der Chart-Hook `dbMigrate` bleibt aus.

Ablauf je Upgrade:

1. Release Notes aller übersprungenen Versionen lesen (Abschnitt „Upgrade
   notes“). 4.5.19 → 4.6.9: 34 Pre-Deployment-Migrationen, keine
   Post-Deployment-Migration; Ruby/Node/FFmpeg/libvips stecken im Image.
   4.6.1–4.6.9 verlangen für Docker nur einen Neustart (geprüft 22.10.2026;
   `db/migrate` und `db/post_migrate` sind in v4.6.5 und v4.6.9 gleich).
2. Backup-Stand prüfen: WAL-Archivierung von `mastodon-pg` aktuell
   (`ContinuousArchiving` = True), Zeitpunkt vor dem Merge notieren (PITR-Ziel).
   Ein zusätzliches On-demand-Backup braucht Schreibzugriff und wird von einem
   Menschen angestoßen.
3. Für 4.7: Migrationsdauer vorher an einem Restore-Klon aus
   `backup-mastodon` messen, auf einem Host in Potsdam, nicht im Cluster
   (unten), und `activeDeadlineSeconds` der Hooks anpassen.
4. Zeitpunkt wählen. Ein festes Sperrfenster gibt es seit 4.7 nicht mehr: Der
   tägliche `FollowRecommendationsScheduler` pflegt `account_summaries` und
   `global_follow_recommendations` als Tabellen in Batches
   (`INSERT … ON CONFLICT`) und sperrt nur Zeilen. Bis 4.6 lief dort ein
   `REFRESH MATERIALIZED VIEW` über 17 bis 27 min, hinter dem jede Migration
   auf `accounts` wartete
   ([Learning](../learnings/mastodon-migration-lock-stau.md)). Direkt vor dem
   Merge lange Transaktionen prüfen:

   ```bash
   primary=$(kubectl -n mastodon get cluster mastodon-pg -o jsonpath='{.status.currentPrimary}')
   kubectl -n mastodon exec "$primary" -c postgres -- psql -XAt -c \
     "select pid, now()-xact_start, left(query,80) from pg_stat_activity
      where backend_type='client backend' and now()-xact_start > interval '1 minute'"
   ```

5. PR mergen. ArgoCD: PreSync-Job → Rollout → PostSync-Job. Web, Streaming
   und Sidekiq `default` rollen (`maxSurge: 1`); alte und neue Version laufen
   dabei kurz parallel, was die Pre-Migrationen erlauben. Nur der
   Sidekiq-Scheduler wechselt per `Recreate` (mastodon-betrieb.md).
   Während die Hooks laufen, gestaute Abfragen beobachten
   (`select count(*) from pg_stat_activity where cardinality(pg_blocking_pids(pid)) > 0`).
   Die Hooks setzen `lock_timeout=10s` und wiederholen bei Lock-Timeouts bis
   zu zehnmal; ein länger laufender Blocker lässt den Job scheitern, nicht die
   Seite.
6. Prüfen: beide Hook-Jobs `Complete`, Logs ohne Fehler; Web, Streaming und
   Sidekiq laufen auf dem neuen Image; Sidekiq-Retries/Dead-Set unauffällig;
   Föderation, Push und Medien-Upload kurz testen.

Schlägt der PreSync-Job fehl, bricht der Sync ab und die alten Pods laufen
weiter: Logs lesen, Ursache beheben, erneut syncen. Nach Lock-Timeouts einer
`concurrently`-Migration vorher nach `INVALID`-Indizes sehen
(`select indexrelid::regclass from pg_index where not indisvalid`). Einen
Rückweg auf die Vorversion gibt es nach erfolgreichen Migrationen nur per PITR.

### 4.6.9 → 4.7.3: Vorbereitung

Stand 24.10.2026, geprüft per `git diff v4.6.9 v4.7.3` im Mastodon-Repo und
mit den Release Notes 4.7.0 bis 4.7.3.

**Ziel ist direkt v4.7.3.** 4.7.1 behebt 4.7-Migrationen, die nach einem
Abbruch nicht sauber neu starten (#40264). Das ist mit unseren Hook-Wiederholungen
wichtig. Chart 1.2.5 hat schon `appVersion` v4.7.3, ein Chart-Bump ist also nicht
nötig.

- Die Abhängigkeiten sind seit 4.6.0 gleich: PostgreSQL ≥ 14 (wir: 16.15),
  Redis ≥ 7 (wir: Valkey 9.2). Ruby 4.0.6, FFmpeg 9.0.2 und libvips 8.18.5
  stecken im Image.
- Es gibt keine neuen Pflicht-Variablen: `.env.production.sample`,
  `config/database.yml` und `config/sidekiq.yml` sind unverändert. Neu und
  optional ist `ES_QUERY_TIMEOUT`, das betrifft uns nicht, weil die Suche nicht
  angebunden ist.
- Cookies von Mastodon ≤ 4.2 gelten nicht mehr. Wer seit 4.3 nicht mehr da
  war, wird abgemeldet.

**Migrationen:** 19 Pre-Deployment- und 8 Post-Deployment-Migrationen. Die
meisten sind kleine Spalten- und Index-Änderungen, `lock_timeout` und
`concurrently` decken sie ab. Diese brauchen Aufmerksamkeit:

| Migration | Phase | Was passiert | Risiko bei uns |
|---|---|---|---|
| `20260728145403 UpdateAccountSummariesToVersion3` | Pre | Baut `account_summaries` als neue Materialized View komplett neu. In **derselben Transaktion** werden beide Views gelöscht, umbenannt, und `global_follow_recommendations` wird neu befüllt. | Der Neubau entspricht dem täglichen Refresh, der auf Ceph über 14 min lief. Während `global_follow_recommendations` neu befüllt wird, hält die Migration `ACCESS EXCLUSIVE` auf beiden Views. Folgeempfehlungen der 4.6-Pods (`/api/v2/suggestions`, Admin) warten so lange. Ein Lock-Timeout beim `DROP` rollt alles zurück, der nächste Versuch rechnet von vorn. |
| `20260702144128 MigrateLocalAccountKeypairs` | Post | Verschiebt die privaten Schlüssel lokaler Accounts nach `keypairs`, verschlüsselt mit `ACTIVE_RECORD_ENCRYPTION_*`, und leert `accounts.private_key`. | Danach hängen die Föderations-Signaturen an den `are-*`-Schlüsseln in `mastodon-secret` (SOPS). Ein DB-Restore ohne dieses Secret ist ab dann wertlos. |
| `20260720100326 FixBlankAccountUri` und `20260720124731 CleanUpInvalidAccounts` | Post | Setzt leere `uri` auf `NULL` und löscht danach **Fremd**-Accounts ohne `uri` per `delete_all`. Die Fremdschlüssel der DB kaskadieren dabei. | Die Menge ist unbekannt, vorher zählen (unten). |
| `20260720104058 AddUniqueIndexOnAccountsUri` | Post | Unique-Index auf `accounts.uri`, `concurrently`. Gibt es Duplikate, führt die Migration die Accounts Zeile für Zeile zusammen. | Mit Duplikaten wird das langsam, vorher zählen. |
| `20260804081821 ConvertMaterializedViewsToTables` | Post | Kopiert beide Views in normale Tabellen. | **Danach gibt es den Lock-Stau aus dem 4.6-Learning nicht mehr.** 4.7 pflegt die Tabellen in Batches (`INSERT … ON CONFLICT`) statt per `REFRESH MATERIALIZED VIEW`. Zwischen Rollout und PostSync überspringt der 4.7-Scheduler den Refresh (`table_exists?` ist für eine View falsch). Das ist harmlos. |

**Vorab-Abfragen** (nur lesend, auf dem aktuellen Primary; `kubectl exec` macht
ein Mensch). `-i` reicht das SQL an `psql` weiter, ohne `-i` läuft nichts:

```bash
primary=$(kubectl -n mastodon get cluster mastodon-pg -o jsonpath='{.status.currentPrimary}')
kubectl -n mastodon exec -i "$primary" -c postgres -- \
  psql -XA -v ON_ERROR_STOP=1 -d mastodon_production <<'SQL'
-- Duplikate, die AddUniqueIndexOnAccountsUri zusammenführen müsste
select count(*) as uri_duplikate from (select uri from accounts where uri <> '' group by uri having count(*) > 1) d;
-- Fremd-Accounts, die CleanUpInvalidAccounts löscht
select count(*) as fremd_ohne_uri from accounts where domain is not null and coalesce(uri, '') = '';
-- Umfang der Keypair-Migration und der Views
select count(*) as lokale_schluessel from accounts where domain is null and private_key is not null;
select (select count(*) from account_summaries) as summaries, (select count(*) from global_follow_recommendations) as recommendations;
-- Muss leer sein
select indexrelid::regclass as invalid_index from pg_index where not indisvalid;
SQL
```

**Restore-Klon und Messung** (Schritt 3 oben). Der Klon läuft **nicht im
Cluster**, sondern auf einem Wegwerf-Host in Potsdam im LAN von Garage. Er
stellt das letzte Backup aus `backup-mastodon` wieder her und testet damit
zugleich das Backup.

> Kein Klon per CNPG-`bootstrap.recovery` im Cluster. Am 24.10.2026 zog
> `mastodon-pg-klon` Basis-Backup (24,7 GB) und WAL über VPN und WAN2 nach
> Halbe. Damit fielen ab 05:43 UTC alle Dienste auf 185.89.37.138 aus, und Ceph
> meldete langsame Operationen. Erst die Umstellung von `halbe`, `mail` und
> jit.social auf die Telekom brachte sie zurück
> ([Learning](../learnings/restore-klon-ueber-vpn.md)).

Host: VM oder LXC (mit `nesting=1,keyctl=1`) auf u22 (192.168.23.5), dem
Proxmox-Host von `garage-s3-potsdam`, im Netz 192.168.23.0/24, mit Docker.
Größe 4 Kerne, 4 GB RAM (mehr hat u22 nicht frei), 100 GB auf `local-zfs`,
nicht auf `data`/`md0` (Garage) oder `vmimages` (Ceph). Potsdam geht über die
eigene Leitung ins Internet, die Image-Pulls belasten Halbe nicht.
`cfgmgmt01` ist zu klein (3 GB RAM, 35 GB frei).

Das Skript [`scripts/ops/mastodon-klon-messung.sh`](../../scripts/ops/mastodon-klon-messung.sh)
nutzt dasselbe CNPG-Image wie `mastodon-pg`, holt Basis-Backup und WAL mit
`barman-cloud-restore`/`barman-cloud-wal-restore` und schaltet die Archivierung
ab (`archive_mode=off`). Der Backup-Pfad der Produktion wird also nur gelesen.
Danach laufen die Vorab-Abfragen von oben, ein `REFRESH` von
`account_summaries` als Hardware-Vergleich (Produktion: Laufzeit des
`FollowRecommendationsScheduler` im Scheduler-Log) und beide
Phasen mit dem neuen Image, als `mastodon` mit `lock_timeout=10s` und 1,5 GiB
Speicherlimit wie im Hook. S3 ist dabei aus, Sidekiq läuft nicht.

Vorbereiten vom Arbeitsplatz aus, im Repo-Root (lesendes `kubectl`, SOPS-Key).
Die Secrets gehen direkt per SSH auf den Host und landen nicht lokal auf der
Platte:

```bash
set -o pipefail
klon=root@<klon-host>
ssh "$klon" 'install -d -m 700 /srv/mastodon-klon'
scp scripts/ops/mastodon-klon-messung.sh "$klon":/srv/mastodon-klon/
sops -d apps/base/mastodon/backup-s3.sops.yaml \
  | yq '.stringData | ("AWS_ACCESS_KEY_ID=" + .ACCESS_KEY_ID, "AWS_SECRET_ACCESS_KEY=" + .SECRET_ACCESS_KEY, "AWS_DEFAULT_REGION=" + .region)' \
  | ssh "$klon" 'umask 077; cat > /srv/mastodon-klon/s3.env'
{
  kubectl -n mastodon get cm mastodon-env -o json | jq -r '.data | to_entries[] | "\(.key)=\(.value)"'
  sops -d apps/base/mastodon/secret.sops.yaml | yq 'select(.metadata.name == "mastodon-secret") | .stringData
    | ("SECRET_KEY_BASE=" + .["secret-key-base"],
      "VAPID_PRIVATE_KEY=" + .["vapid-private-key"],
      "VAPID_PUBLIC_KEY=" + .["vapid-public-key"],
      "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=" + .["are-primary-key"],
      "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=" + .["are-deterministic-key"],
      "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=" + .["are-derivation-salt"])'
} | ssh "$klon" 'umask 077; cat > /srv/mastodon-klon/mastodon.env'
```

Ein Fehler in `sops`, `yq` oder `kubectl` kann trotzdem eine unvollständige
Datei hinterlassen. Das Skript prüft deshalb vor dem Start, ob alle nötigen
Schlüssel gesetzt sind. Die echten `are-*`-Schlüssel sind nötig: `MigrateLocalAccountKeypairs`
verschlüsselt damit, und vorhandene verschlüsselte Spalten lassen sich nur mit
ihnen lesen.

Ausführen auf dem Host in `tmux`, die Restore-Phase dauert je nach WAL-Menge
Stunden:

```bash
ssh -t "$klon" tmux new -s klon \
  'MASTODON_IMAGE=ghcr.io/mastodon/mastodon:v4.7.3 /srv/mastodon-klon/mastodon-klon-messung.sh all'
```

Das Skript nimmt das neueste vollständige Basis-Backup, ein anderes wählt man mit
`BACKUP_ID=<id>`. Das planmäßige Backup läuft sonntags um 02:00 UTC
(`backup.yaml`), kurz danach ist am wenigsten WAL einzuspielen. Stimmt
`PG_IMAGE` nicht mehr mit `database.yaml` überein, das Image von dort mitgeben.
`restore` und `measure` lassen sich auch einzeln starten. Die Postgres-Container
laufen mit 2 CPUs (`KLON_CPUS`), weil u22 auch PBS und Garage trägt.

Stand 25.10.2026: CT 8031 `mastodon-klon` (192.168.23.31) auf u22, Debian 13,
4 Kerne, 4 GB RAM, 100 GB auf `local-zfs`, angelegt nach dem Muster von
`garage-s3-potsdam`. Basis-Backup `20261025T020001` in 116 s geladen, WAL in 33 s.
Nach der Messung gelöscht (`pct destroy 8031 --purge 1`), für die nächste mit
denselben Werten neu anlegen.

Ergebnis in `/srv/mastodon-klon/logs/`. `summary.txt` enthält:

- die Dauer von Pre- und Post-Phase,
- die Dauer des `REFRESH` im Vergleich zur Produktion. Daraus ergibt sich, um
  welchen Faktor der Host schneller oder langsamer ist als Ceph,
- die zehn langsamsten Migrationen,
- die Schritte von `UpdateAccountSummariesToVersion3`. Ab
  `drop_view(:global_follow_recommendations)` warten die Folgeempfehlungen. Bei
  mehr als etwa einer Minute ein Zeitfenster mit wenig Last wählen.

`vorab.txt` und `danach.txt` enthalten die Abfragen von oben, angewendet auf den
Klon. Der Klon hat keine Last und keinen Standby. Die Zeiten deshalb mit dem
`REFRESH`-Faktor umrechnen, die Produktion braucht eher länger.

**Ergebnis 25.10.2026** (v4.6.9 → v4.7.3, Basis-Backup `20261025T020001`,
Postgres auf 2 CPUs begrenzt). Alle 19 Pre- und 8 Post-Migrationen liefen ohne
Fehler und ohne Lock-Timeout.

Zum Vergleich dient die Laufzeit des täglichen `FollowRecommendationsScheduler`
in der Produktion (Log von `mastodon-sidekiq-scheduler`, `elapsed=`): 1.613 s am
24.10. und 1.024 s am 25.10., beide Male bei `HEALTH_ERR` mit langsamen OSDs. Der
Job macht etwas mehr als den `REFRESH`, der Faktor ist also eine obere Grenze:
etwa 3,8 (25.10.) bis 6 (24.10.). Die 14 min vom 23.10. waren nur der Stand beim
Abbruch und taugen nicht als Vergleich.

| | Klon | Produktion, Faktor 3,8 | Produktion, Faktor 6 |
|---|---|---|---|
| `REFRESH account_summaries` | 268 s | – | – |
| Pre-Phase gesamt | 283 s | etwa 18 min | etwa 28 min |
| davon `UpdateAccountSummariesToVersion3` | 277 s, fast alles im Neubau der View | etwa 18 min | etwa 28 min |
| Sperre auf den Views (ab `rename_index` bis Commit) | 3,5 s, davon 3,4 s `create_view(:global_follow_recommendations)` | etwa 13 s | etwa 21 s |
| Post-Phase gesamt | 20 s | etwa 1,5 min | etwa 2 min |
| davon `ConvertMaterializedViewsToTables` | 10,6 s | etwa 40 s | etwa 1 min |

Danach: Beide Views sind Tabellen (`relkind = r`). `keypairs` mit `#main-key`
enthält 732 Einträge, gleich den lokalen Schlüsseln vorher, und
`accounts.private_key` ist überall leer. Ungültige Indizes gibt es keine.
`CleanUpInvalidAccounts` löschte den einen Fremd-Account ohne `uri`
(`Longuich@meow.social`). Die Tabellen enthalten 125.249 Summaries und 1.554
Empfehlungen.

**In der Produktion** (25.10.2026, #386, Ceph mit langsamen OSDs):

| | Klon | Produktion | Faktor |
|---|---|---|---|
| Pre-Phase gesamt | 283 s | 965 s (07:45:51–08:01:56Z) | 3,4 |
| davon Neubau `account_summaries` | 274 s | 889 s | 3,2 |
| Sperre auf den Views | 3,5 s | etwa 31 s | 9 |
| davon `create_view(:global_follow_recommendations)` | 3,4 s | 30,5 s | 9 |
| Post-Phase gesamt | 20 s | 132 s (08:03:46–08:05:58Z) | 6,6 |
| davon `ConvertMaterializedViewsToTables` | 10,6 s | 115,6 s | 11 |

Die Schätzung über die Scheduler-Laufzeit lag für die Neubauten gut, für die
Schritte mit vielen Joins und Schreibvorgängen (Empfehlungen, Kopie in
Tabellen) zu niedrig. Für die nächste Messung bei solchen Schritten mit
Faktor 10 rechnen. Gestaute Abfragen gab es während der 31 s Sperre keine.

Nach dem Upgrade fehlten in der Produktion 104 lokale Accounts gegenüber dem
Klon. Das kam nicht von den Migrationen, sondern vom `UserCleanupScheduler`,
der unbestätigte Anmeldungen nach 7 Tagen löscht und im alten Scheduler-Pod
zwischen Zählung und Rollout lief
([Learning](../learnings/mastodon-anmeldespam-mailversand.md)). Vorher/Nachher
deshalb mit der Zahl lokaler Accounts **zum Zeitpunkt der Prüfung**
vergleichen, nicht mit einer Zählung von früher.

Folgen für den Upgrade-PR:

- `activeDeadlineSeconds` des PreSync-Hooks auf 5400: das Dreifache von 28 min
  wären 84 min. Der PostSync-Hook bleibt bei 3600.
- Die Folgeempfehlungen warten 13 bis 21 s. Ein eigenes Zeitfenster mit wenig
  Last ist nicht nötig. Nicht mergen, solange der tägliche Refresh läuft, siehe
  Schritt 4 unten.
- Die Pre-Phase dauert 18 bis 28 min. Der PreSync-Hook hält den Sync so lange
  an, die 4.6-Pods laufen in der Zeit weiter.

Aufräumen mit `/srv/mastodon-klon/mastodon-klon-messung.sh cleanup`. Der Befehl
löscht Container, Daten und die Env-Dateien mit den Secrets, die Logs bleiben.
Danach den Host löschen.

**Upgrade-PR**, erst nach der Messung:

1. `v4.6.9` → `v4.7.3` an allen acht Stellen: `values.yaml` (2),
   `db-migrate.yaml` (2), `media-retention.yaml` (4). Den Kommentar zur
   `appVersion` in `kustomization.yaml` anpassen. `guardrails.sh` prüft, dass
   alle Mastodon-Tags gleich sind.
2. `renovate.json`: `allowedVersions` auf `/^v4\.7\.\d+$/` stellen.
   5.0 braucht wieder einen eigenen Schritt.
3. `activeDeadlineSeconds` beider Hooks auf etwa das Dreifache der gemessenen
   Phase setzen, mindestens 3600. Nach der Messung vom 25.10.: PreSync 5400,
   PostSync 3600. Ein Lock-Timeout am Ende von
   `UpdateAccountSummariesToVersion3` wiederholt den teuren Neubau. 5400 s
   reichen für zwei bis drei Versuche, danach bricht der Sync ab und die
   4.6-Pods laufen weiter.
4. Nur für das Upgrade von 4.6 aus (erledigt): nicht während des täglichen
   4.6-Refreshs mergen. Der Scheduler-Pod würfelt die Uhrzeit beim Start aus
   und behält sie; zählte nur eine `done`-Zeile von heute
   (`kubectl -n mastodon logs deploy/mastodon-sidekiq-scheduler
   --since-time="$(date -u +%Y-%m-%dT00:00:00Z)" | grep FollowRecommendationsScheduler`).
   Direkt davor zusätzlich prüfen, ob gerade ein Refresh läuft:
   `select pid, now()-query_start from pg_stat_activity where state = 'active' and query ilike 'refresh materialized%'`.
5. Danach prüfen:
   - `select relkind from pg_class where relname in ('account_summaries','global_follow_recommendations')`
     liefert zweimal `r`.
   - `select count(*) from keypairs where local_fragment = '#main-key'`
     entspricht `select count(*) from accounts where domain is null`, beide
     zum selben Zeitpunkt gezählt. Am 25.10.: 628 und 628.
   - Ein Follow zu und von einer fremden Instanz funktioniert, also auch die
     Signaturen.
   - Am nächsten Tag hat der Scheduler die Folgeempfehlungen wieder gefüllt.
6. Erledigt am 25.10.2026: Learning
   [mastodon-migration-lock-stau.md](../learnings/mastodon-migration-lock-stau.md)
   um „ab 4.7 kein `REFRESH MATERIALIZED VIEW` mehr“ ergänzt, das Sperrfenster
   06–10 UTC in Schritt 4 entfernt.
