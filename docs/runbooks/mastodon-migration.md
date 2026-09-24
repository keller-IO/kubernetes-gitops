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

Keine mehr — beide sind entschieden:

- **Volltextsuche** (23.09.2026): wird separat behandelt. Elasticsearch bleibt
  deaktiviert, der Cutover läuft ohne Volltextsuche. Nachrüsten später per
  OpenSearch und `tootctl search deploy`.
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
- Danach mastodon02 stilllegen; Mastodon-Upgrade auf 4.6 separat.
