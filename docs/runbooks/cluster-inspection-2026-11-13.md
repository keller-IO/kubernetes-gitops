# KellerIO-Clusterinspektion vom 13.11.2026

Momentaufnahme vom 13.11.2026, etwa 06:00–08:00 UTC, aus dem LAN. Die Inspektion selbst
war read-only; es wurden keine Secrets ausgelesen. Die Ergebnisse beschreiben den
Prüfzeitraum und sind keine dauerhafte Verfügbarkeitsgarantie. Hauptbefund: Der Cluster
ist im Soll. Behoben wurden zwei seit Längerem offene Lücken (PR #481): die fehlende
Obergrenze für von Replikationsslots zurückgehaltenes WAL und die fehlenden
CNPG-Alarmregeln. Neu ist ein OOM-Kill von Roundcube am 12.11.; für `yealink` ist die
Ursache jetzt belegt, die Behebung steht noch aus.

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 13.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions |
| ArgoCD | Alle Apps Synced und Healthy | 47 Applications, 46 Synced/Healthy, 1 Progressing: `yealink` (bekannt) |
| Pods | Keine Störungen | Kein Pending-, CrashLoop- oder Failed-Pod; ein OOM-Kill bei `roundcube` am 12.11. (siehe unten) |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49 Zertifikate Ready, nächster Ablauf `flurfunk-tls` am 17.12., keine offenen Challenges |
| Jobs | Keine Fehlschläge | Keine fehlgeschlagenen Jobs; CronJobs `renovate` und `jitmgmt-staging/rechnungslauf` sind suspendiert |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 57 PV / 57 PVC, alle `ceph-rbd` und Bound; 52 VolumeAttachments ohne Fehler; keine PVC über 70 % |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, `reserved`, 0 B zurückgehalten |
| Backups | Täglich erfolgreich | Alle 10 CNPG-Cluster aktuell (`mastodon-pg` wöchentlich, 08.11.), MariaDB- und Offsite-Jobs vom 13.11. |
| Notifications | Zustellung ohne Fehler | Alertmanager: 8 Mails in 48 h, 0 Fehlschläge, keine Silences |

Kubernetes-Events reichen nur etwa eine Stunde zurück. Aussagen über 48 h stützen sich
deshalb auf Metriken (`ALERTS`, Restart-Zeitstempel), nicht auf Events.

## Alarme (48 h)

- Cluster-Alertmanager: Aktiv sind nur `KubeDeploymentReplicasMismatch` und
  `KubePodNotReady` (beide `yealink`, seit 02.11.) sowie `Watchdog`. Im Fenster wurde
  nichts aufgelöst außer `InfoInhibitor` (2 Einzelsamples). Kein Flattern, keine Silences,
  keine Inhibit-Regeln.
- Zustellung: `alertmanager_notifications_failed_total` ohne Zuwachs, keine Fehlerzeilen
  im Alertmanager-Log. Ob die Mails beim Empfänger ankommen, wurde nicht geprüft.
- vmalert: alle Regelgruppen ohne `lastError`; kein Scrape-Ziel dauerhaft down
  (`crowdsec-pg` einmalig am 13.11. 00:13 UTC, ein Remote-Write-Fehler am 11.11. 12:51 UTC).
- Gatus meldete `webmail` am 12.11. 16:43 UTC einmal als fehlgeschlagen; das ist der
  Roundcube-OOM-Kill.
- Der `Watchdog` geht an `null`. Es gibt keinen externen Dead-Man-Switch; ein stiller
  Ausfall der Mailkette fiele nicht auf.
- Grafana auf vizmon01 und Ceph wurden diesmal nicht geprüft.

## Speicher

- Alle 57 PVCs sind Bound, keine Resize-Vorgänge, VolumeAttachments 1:1 zu den gemounteten
  PVCs, CSI-Pods gesund. Höchste Belegung: `vmsingle` 48 %, `mastodon-pg` 36 %. Inodes
  höchstens 4 %. Keine PVC läuft nach dem 7-Tage-Trend in 30 Tagen voll.
- Verzeichnisbelegung gegen kubelet-Metrik: Bei allen 52 gemounteten PVCs stimmen
  kubelet-Metrik, `df` und `du -sx` bis auf wenige KiB überein. Keine gelöschten, aber
  offenen Dateien, keine überdeckten Mounts, kein read-only gemountetes Volume.
  `goloom-data` ist nicht messbar (Image ohne Shell), dort gilt nur die Metrik (0,03 %).
- Statische lokale PVs: Es gibt keine. Kein PV hat `spec.local` oder `spec.hostPath`,
  keine StorageClass nutzt `kubernetes.io/no-provisioner`. Die Prüfung auf gemeinsam
  genutzte Dateisysteme ist damit für PVs gegenstandslos.
- Gemeinsam genutzt wird nur `/var` der Nodes (Images, Logs, Ephemeral). Frei: Control
  Plane 9,4–9,8 GiB von 17,8; `wrk1` 23,2 GiB, `wrk2` 17,0 GiB (−3,4 GiB in 7 Tagen),
  `wrk3` 21,4 GiB, `wrk4` 11,7 GiB, `wrk5` 14,8 GiB (−3,9 GiB in 7 Tagen). Kein
  DiskPressure, keine Evictions.
- Vier VolumeSnapshots mit `Retain` von Ende Juli/Anfang August liegen noch
  (`mailman-core-pre-052-…`, `mailman-web-pre-052-…`, `paperless-data-pre-22015-…`,
  `paperless-media-pre-22015-…`).

## Replikationsslots und WAL

Alle 10 CNPG-Cluster sind 2/2 gesund, jede Instanz wurde einzeln abgefragt. Je ein aktiver
physischer Slot `_cnpg_<cluster>_<n>` auf dem Primary mit `wal_status=reserved`,
zurückgehalten 0 B, Replay-Lag 0 Byte. Keine Slots auf den Replicas, keine logischen
Slots, keine Slots zu nicht mehr vorhandenen Instanzen. `pg_wal` 480–624 MiB,
`archive_status` ohne `.ready`-Dateien. Seit dem 11.11. kein neuer Archivierungsfehler.
MariaDB: fünf Einzelinstanzen ohne Replikation.

**Behoben mit PR #481:** `max_slot_wal_keep_size` stand überall auf `-1`. Jetzt gilt
`2GB` für die acht 5-Gi-Cluster, `8GB` für `mailman-pg` (30 Gi) und `16GB` für
`mastodon-pg` (64 Gi). Der Parameter wirkt per Reload; nach dem Ausrollen melden alle zehn
Primaries den neuen Wert ohne Neustart oder Switchover. Kehrseite: Überschreitet ein
ausgefallenes Standby die Grenze, wird sein Slot ungültig und es zieht aus dem WAL-Archiv
nach oder wird neu aufgebaut. Dieser Fall wurde nicht ausgelöst. Gegen einen Stau durch
ein nicht erreichbares Archivziel hilft die Grenze nicht.

## Backups

- CNPG: alle Cluster mit `ContinuousArchiving=True` und `LastBackupSucceeded=True`,
  letztes Basebackup am 13.11. zwischen 02:00 und 02:55 UTC, `mastodon-pg` planmäßig am
  08.11. `goloom-pg` läuft seit dem 12.11. wieder. Die 33 `failed`-Backup-Objekte sind
  Altlasten (zuletzt 03.11. und `goloom` am 11.11.).
- MariaDB-`Backup`-CRs und die Offsite-CronJobs liefen am 13.11. erfolgreich.
- `goloom-backup` meldet weiter `noch kein /data/media`; der übrige Job überträgt 7.485
  Objekte (453 MiB).
- Ob am Garage-Ziel tatsächlich Objekte liegen, wurde nicht direkt geprüft.

**Behoben mit PR #481:** Der Cluster hatte keine einzige Alarmregel für CNPG. Die VMRule
`monitoring/cnpg-alerts` (`infrastructure/base/monitoring/vmrule-cnpg.yaml`) bringt elf
Regeln: inaktiver Slot, zurückgehaltenes WAL über 1 GiB, hängende Archivierung,
Archiv-Rückstand, veraltetes Basebackup (36 h, `mastodon-pg` 8 Tage), fehlgeschlagenes
Backup ohne späteren Erfolg, fehlendes streamendes Replica, Replay-Lag, Exporter down und
fehlende Metriken. vmalert hat die Regeln geladen, keine feuert. Im 14-Tage-Rückblick
hätten sie die Backup-Fehlschläge vom 03.11. und `goloom` am 11.11. gemeldet, die kurzen
Garage-Aussetzer von 1–12 Minuten dagegen nicht.

## Roundcube: OOM-Kill am 12.11.2026

- Der Container `roundcube` wurde am 12.11. um 16:43 UTC vom Kernel beendet
  (`CONSTRAINT_MEMCG`, Limit 768Mi); Webmail war rund zwei Minuten nicht erreichbar.
- Der Speicher lag bis 30 Sekunden vor dem Kill konstant bei 177 MiB und sprang dann über
  das Limit. Es ist also kein Leck und keine Dauerlast.
- Der Kernel-Bericht zeigt elf Apache-Prozesse, drei davon mit 304, 190 und 167 MiB
  anonymem Speicher. PHP erlaubt je Request nur 64 MiB (`memory_limit`); der Speicher
  lag also außerhalb der PHP-Verwaltung.
- Roundcube 1.7.4 erzeugt Bildvorschauen mit der PHP-Erweiterung Imagick
  (`rcube_image.php`). ImageMagick darf im Image je Prozess 1 GiB Arbeitsspeicher und
  2 GiB Memory-Map nutzen, mehr als das Pod-Limit. Im Log steht unmittelbar vor dem Kill
  eine Nachrichtenvorschau; kurz davor lief eine Vorschaubild-Anfrage (`_thumb=1`).
- Einschätzung: Sehr wahrscheinlich haben mehrere gleichzeitige Vorschaubilder großer
  Bildanhänge den Speicher belegt. Nicht bewiesen, weil die Nachricht nicht eingesehen
  wurde. Kleinere Spitzen derselben Art: 449 MiB am 05.11., 405 MiB am 11.11., 426 MiB am
  12.11. abends.
- Vorschlag (nicht umgesetzt): ImageMagick im Pod per `MAGICK_MEMORY_LIMIT`,
  `MAGICK_MAP_LIMIT`, `MAGICK_AREA_LIMIT` und `MAGICK_DISK_LIMIT` begrenzen, sodass große
  Bilder auf Platte ausweichen oder die Vorschau entfällt. Ein höheres Pod-Limit allein
  hilft nicht verlässlich, weil drei Prozesse zusammen bis zu 3 GiB belegen dürfen.

## yealink: Ursache belegt

- `nextcloud-yealink-phonebook` ist seit 02.11. 0/1; die Readiness-Probe liefert 503, weil
  die CardDAV-Abfrage an `jit.cloud` mit 401 scheitert.
- Letzter Erfolg laut nginx auf nc04: 02.11. 15:50 MEZ. Ab 16:05 MEZ meldet Nextcloud
  `Session token credentials are invalid` und `TokenPasswordExpiredException`.
- Ursache: Der Dovecot-Hänger auf mail05 am 02.11. (16:00–17:04 MEZ) ließ die
  IMAP-Passwortprüfung von `user_external` scheitern; Nextcloud hat daraufhin das
  App-Passwort `phonebookneu` entwertet. Das Token existiert noch, ist aber ungültig.
- Behebung: neues App-Passwort ohne hinterlegtes Login-Passwort (`occ
  user:auth-tokens:add --no-interaction`), dann wird es nicht mehr gegen IMAP geprüft;
  anschließend `nextcloud-app-password` in `secret.sops.yaml` ersetzen. Die App liest das
  Secret bei jedem Abruf neu, ein Neustart ist nicht nötig. Steht noch aus.

## Offene Punkte

- **yealink:** neues App-Passwort anlegen und ins Secret übernehmen (siehe oben).
- **Roundcube:** ImageMagick-Grenzen setzen (siehe oben).
- **Node-Platz:** `/var` auf `wrk5` und `wrk2` beobachten, `wrk4` hat 11,7 GiB frei.
- **Dead-Man-Switch:** `Watchdog` an ein externes Ziel leiten.
- **Garage-Erreichbarkeit:** Ursache der Aussetzer vom 03., 08. und 11.11. weiter offen.
- **`mastodon-pg`:** Basebackup nur wöchentlich (unverändert).
- **Verwaiste PVCs:** `authentik/data-authentik-valkey-0`, `kite/kite-storage`,
  `wordpress-3/wordpress`, `wordpress-3/data-wordpress-mariadb-0` (unverändert).
- **VolumeSnapshots:** vier Pre-Upgrade-Stände von Juli/August prüfen und ggf. löschen.
- **Ohne Backup:** Mailman-`var/queue`, Dateien von `wordpress-3`, `jitmgmt-fints`,
  `kite-storage` (unverändert).
- **`mastodon/data-mastodon-search-0`:** 10-Gi-Volume praktisch leer (unverändert).
- **`ciso-assistant-pg`, `roundcube-pg`:** noch PostgreSQL 17.2, die übrigen 17er 17.11.
