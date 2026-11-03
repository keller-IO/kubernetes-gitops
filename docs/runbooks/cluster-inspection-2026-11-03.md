# KellerIO-Clusterinspektion vom 03.11.2026

Read-only-Momentaufnahme vom 03.11.2026, etwa 07:45–08:10 UTC. Der Zugriff kam vom
Konferenz-WLAN über NetBird; das Netz 192.168.2.0/24 hinter `pve` war nicht direkt
erreichbar und wurde über einen SOCKS-Proxy auf `pve` angesprochen. Es wurden keine
Ressourcen geändert und keine Secrets ausgelesen. Die Ergebnisse beschreiben den
Prüfzeitraum und sind keine dauerhafte Verfügbarkeitsgarantie. Hauptbefund: In der
Nacht auf den 03.11. schlugen 5 von 9 CNPG-Basisbackups fehl, ohne dass ein Alarm
ausgelöst wurde. Die Ursache liegt außerhalb dieses Repos (Host `u22`); die Fixes dort
und im zentralen Ansible-Repo sind unten eingeordnet.

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 03.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions, kein Cordon. Reboots des CVE-Rollouts: wrk5 02.11. 15:03, wrk4 und cp1 02.11. 16:37, cp3 03.11. 04:43, wrk2 03.11. 05:36 UTC |
| ArgoCD | Alle Apps Synced und Healthy | 47 Applications, 46 Synced/Healthy, 1 Progressing: `nextcloud-yealink-phonebook` (bekannt, siehe unten) |
| Pods | Keine Störungen | Kein Terminating-, Pending- oder CrashLoop-Pod; keine OOMKills in 48 h |
| Zertifikate | Ready, nicht kurz vor Ablauf | Alle Ready, frühester Ablauf 08.12.2026 (`collabora-tls`) |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 58 PVCs / 58 PVs Bound, alle `ceph-rbd` |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, 0 B zurückgehalten |
| Backups | Täglich erfolgreich | **5 von 9 täglichen CNPG-Basisbackups in der Nacht auf den 03.11. fehlgeschlagen** (siehe Hauptbefund) |
| Alarmierung | Fehlschlag eines Backups erreicht einen Empfänger | Für die 5 Fehlschläge ging kein Alert raus |

## Hauptbefund: Backups in der Nacht auf den 03.11.

Fehlgeschlagen sind die Basisbackups von `mailman-pg` (02:00), `expense-pg` (02:20),
`monitoring-pg` (02:30), `ciso-assistant-pg` (02:40) und `goloom-pg` (02:50). Erfolgreich
waren `paperless-pg`, `roundcube-pg`, `crowdsec-pg` und `netbox-pg`. `mastodon-pg`
sichert nur sonntags.

### Belegt

- Im Pod-Log meldet `barman-cloud-backup` „Connection was closed before we received a
  valid response“ und „Read timeout on endpoint URL“ gegen Garage
  (`192.168.23.21:3900`).
- Das Garage-Log enthält 139 HTTP-500-Antworten „error reading a body from connection“,
  in den Fenstern 02:09–02:58 und 04:46–05:08 UTC (in der Nacht davor: 1). Sie kamen
  von mehreren Nodes, der Fehler ist also nicht node-spezifisch. Auf `kellerio-wrk2`
  entfielen 104 davon; wrk2 trug mit 624 die meisten Upload-PUTs.
- Garage läuft im LXC 8021 auf `u22` (1 Kern, 1 GiB RAM), PBS auf demselben Host. Beide
  schreiben auf `/data` = `md0`, ein RAID1 aus zwei HDDs (15 TB, 88 % belegt).
- Auf `u22` startete Debians `mdcheck_continue.timer` (`OnCalendar=daily`,
  `RandomizedDelaySec=12h`, bis zu 6 h Laufzeit) am 03.11. um 02:47:14 CET = 01:47 UTC
  und lief bis 07:50 UTC über das gesamte Backup-Fenster. Das Array las währenddessen
  mit 150–160 MB/s bei 66–75 % Auslastung. Am 02.11. startete die Prüfung erst um
  04:17 UTC, die Backups um 02:00 liefen alle durch; am 01.11. war der Start 11:09 UTC.
- Die Fehlerfenster fallen mit Upload-Aktivität zusammen; dazwischen (03:00–04:30) gab
  es kaum Uploads und keine Fehler.

### Nur korreliert, nicht nachgestellt

- Dass der RAID-Prüflauf die Garage-Latenz so erhöht hat, dass Uploads in Timeouts
  laufen, ist die plausibelste Erklärung. Sie wurde nicht experimentell nachgestellt.
- Der Garage-Container liegt am 1-GiB-Limit: `memory.peak` am Limit,
  `memory.events high=4281`, `sock_throttled=194460`. Die Zähler sind über 5 Tage
  kumuliert und lassen sich nicht auf die Nacht eingrenzen. Die Containergröße kann
  deshalb Mitursache sein.

### Zustand danach

- Der Prüflauf stand um 07:50 UTC bei 76 % (Sektor 23838057472 von 31251490816). Der
  nächste Lauf ist für Mi 04.11. 07:56 CET gemeldet.
- WAL-Archivierung: Fehler 04:50–05:11 UTC (Exit 4), seit etwa 07:45 UTC archivieren
  alle Primaries wieder, `ContinuousArchiving=True`. Point-in-Time-Recovery ist damit
  weiter möglich; verloren ist nur das jeweilige Basisbackup der Nacht.

### Maßnahmen und Nachweis

- „`mdcheck`-Zeitplan und Alarm `kellerio-cnpg-backup-failed` werden im zentralen
  Ansible-Repo umgesetzt.“ In diesem Repo gibt es dafür keine Änderung.
- **Nächster Nachweis ist der Backup-Lauf am 04.11. ca. 02:00–03:00 UTC; er ist noch
  nicht geprüft.** Erst danach lässt sich sagen, ob der neue Zeitplan die Fehler
  vermeidet. Siehe auch `docs/learnings/garage-mdcheck-backup-window.md`.

### Status-Widersprüche

- `lastSuccessfulBackup` bei `ciso-assistant-pg`, `goloom-pg` und `monitoring-pg` zeigt
  den 03.11., obwohl das zugehörige Backup-Objekt `failed` ist.
- `roundcube-pg` hat ein `completed`-Backup vom 03.11., der Clusterstatus zeigt noch den
  02.11.

Der Clusterstatus ist daher für diese Frage nicht verlässlich; prüfen, ob die
Backup-Objekte und das Pod-Log übereinstimmen.

## Alarmierung

- Für die 5 Fehlschläge ging kein Alert raus. Die Regel „kellerIO CNPG backup stale“
  greift erst nach Stunden bis Tagen und nutzt `last_available`. Sie war vom 02.11.
  10:36 bis 03.11. 03:02 UTC feuernd, aber wegen `netbox-pg` (neuer Cluster ohne erstes
  Backup), nicht wegen der Fehlschläge.
- Die Metrik `cnpg_collector_last_failed_backup_timestamp` ist vorhanden und korrekt
  (5 Namespaces jünger als 6 h). Der Alarm `kellerio-cnpg-backup-failed` baut darauf
  auf (siehe oben, zentrales Ansible-Repo).
- Der Alertmanager hat in 48 h 70 Mails ohne Zustellfehler versendet; der Pod war kurz
  zuvor neu gestartet, der Zähler ist eventuell zurückgesetzt. Die Contact-Points von
  Grafana waren anonym nicht prüfbar.

### Alerts der letzten 48 h

| Zustand | Alert | Einordnung |
| --- | --- | --- |
| aktiv | `KubeDeploymentReplicasMismatch`, `KubePodNotReady` (yealink) | bekannt, siehe offene Punkte |
| aktiv | `KubeJobFailed` `mastodon-media-remove-29885910` | Deadline 28.10.; TTL 7 d läuft etwa 04.11. ab; Folgeläufe OK |
| aktiv | Grafana „Ceph health is not OK“ seit 21.10. | `AUTH_INSECURE_*`, maskiert neue Ceph-Fehler |
| aufgelöst | „kellerIO CNPG backup stale“ | 02.11. 10:36 – 03.11. 03:02, `netbox-pg` ohne erstes Backup, kein Ausfall |
| aufgelöst | `ciso-assistant-pg-2` NotReady | 02.11. 16:55 – 03.11. 05:05 und 05:25–05:30; Standby, Pod ersetzt, Log weg, Ursache offen |
| aufgelöst | Corosync-/OSD-Episoden | passen zu den Reboots |

## Speicher: du gegen kubelet

51 PVCs wurden mit `du` im Container gemessen. Die Abweichung zur kubelet-Metrik beträgt
höchstens 0,01 GiB. `goloom-data` ließ sich nicht messen (kein `sh`/`du` im Container);
das kubelet meldet 1,4 MB. Höchste Belegung: `mailman-web-data` 54 %, `vmsingle` 47 %.
Inodes höchstens 4,1 %.

Ohne Pod, also verwaist:

| Namespace / PVC | Kapazität | Einordnung |
| --- | ---: | --- |
| authentik / `data-authentik-valkey-0` | 1 Gi | kein Pod |
| kite / `kite-storage` | 1 Gi | kein Pod |
| mailman / `mailman-web-index-staging` | 100 Gi | bewusst behalten |
| wordpress-3 / `data-wordpress-mariadb-0` | 8 Gi | kein Pod |
| wordpress-3 / `wordpress` | 5 Gi | kein Pod |

`jitmgmt-fints` wird nur von einem CronJob gemountet und ist nicht verwaist. Es gibt
4 alte VolumeSnapshots mit Retain-Policy (31.07./02.08.); Forgejo-Reste an PVCs gibt es
nicht mehr.

Talos `/var`: `kellerio-wrk1` 81,3 % (7,1 GiB frei, 7-Tage-Minimum 5,9 GiB),
`kellerio-wrk4` 68,7 %, die übrigen 42–47 %. Beobachten: Die Image-GC greift bei 85 %.

## Statische lokale PVs

0 von 58 PVs sind `local`, `hostPath`, `nfs` oder statisch; es gibt keine doppelten
`volumeHandle`s. Das einzige gemeinsame Dateisystem ist das Inline-SMB-Volume
`//192.168.2.75/scanner` (Paperless-Pod und Watchdog-Job). Die kubelet-Metrik zeigt dort
das NAS (etwa 85 % von 25,9 TiB), nicht den Share. Die StorageClass `ceph-fs` hat 0 PVCs.

## Replikationsslots

Alle 10 CNPG-Cluster haben je einen physischen Slot `_cnpg_*`, aktiv, `wal_status`
`reserved`, 0 B zurückgehalten. Es gibt keine logischen und keine inaktiven Slots.
`pg_wal` belegt 84–638 MB, der Replay-Lag beträgt höchstens 6 ms, keine Transaktion läuft
länger als eine Stunde. `max_slot_wal_keep_size` steht auf -1 (unbegrenzt): Ein
hängender Standby würde WAL ohne Obergrenze auf dem Primary halten.

## Weitere Befunde

- **`netbox-valkey-0`:** Die Readiness-Probe `valkey-cli ping` hatte `timeoutSeconds: 1`
  und 24 Timeout-Events in 16 h (zuletzt 03.11. 06:46 UTC); 0 Restarts, laut Alerts nie
  NotReady. Dieser PR setzt Readiness und Liveness auf `timeoutSeconds: 3`
  (`apps/base/netbox/cache.yaml`). Das ersetzt den Pod einmal; die AOF liegt auf dem PVC.
- **Node-Verteilung nach den Reboots:** Memory-Requests wrk3 94 %, wrk1 82 %, wrk5 80 %,
  wrk4 75 %, wrk2 10 %. 8 von 10 CNPG-Primaries liegen auf wrk5. Das gleicht sich nicht
  von selbst aus.
- **Ceph:** `HEALTH_ERR` allein wegen `AUTH_INSECURE_*`, dazu BlueStore-Slow-Ops, ein MDS
  mit übergroßem Cache und `noout` (CVE-Rollout; `pve` und `pve2` stehen noch aus). 497
  PGs `active+clean`. Keine Änderung vorgenommen.
- **Verwaister Service `default/cert-manager-webhook-cloudns`:** ohne Endpoints, per
  `kubectl apply` angelegt (113 Tage alt). Der echte Webhook läuft im Namespace
  `cert-manager`, der APIService ist Available. Bereinigung braucht Schreibzugriff.

## Offene Punkte und Entscheidungen

- **yealink-App-Passwort:** `nextcloud-yealink-phonebook` hatte nie einen erfolgreichen
  Sync (HTTP 401); das Secret braucht ein App-Passwort. Es hält die beiden Yealink-Alerts
  und den Status Progressing.
- **Verwaiste PVCs:** Löschung von `data-authentik-valkey-0`, `kite-storage`,
  `data-wordpress-mariadb-0` und `wordpress` sowie der 4 alten Retain-Snapshots
  entscheiden; dies ist keine Löschfreigabe.
- **`default/cert-manager-webhook-cloudns`:** entfernen, sobald jemand mit
  Schreibzugriff dafür bereitsteht.
- **Node-Verteilung:** Entlastung von wrk5 (CNPG-Primaries) und wrk3 planen; wrk2 ist fast
  leer.
- **`mastodon-pg`:** sichert nur wöchentlich; Umstellung auf täglich offen
  (`apps/base/mastodon/backup.yaml`).
- **Ceph:** `noout` erst nach den Reboots von `pve` und `pve2` entfernen. Der dauerhafte
  `HEALTH_ERR` durch `AUTH_INSECURE_*` maskiert neue Fehler; die Warnung beheben oder
  stummschalten, damit neue Fehler auffallen.
- **Garage-LXC 8021:** 1 GiB RAM und `sock_throttled` prüfen, Größe ggf. erhöhen (ein
  Eingriff am Host `u22`, außerhalb dieses Repos).
- **`ciso-assistant-pg-2`:** Ursache der NotReady-Phasen vom 02./03.11. ungeklärt, das
  Log des früheren Pods ist weg.
- **Status-Widersprüche** bei `lastSuccessfulBackup` (siehe Hauptbefund) klären.
- **`mastodon-media-remove-29885910`:** fehlgeschlagener Job läuft per TTL etwa am 04.11.
  aus; nichts zu tun.
- **Backup-Lauf 04.11.:** ca. 02:00–03:00 UTC prüfen (Backup-Objekte, `Read timeout` im
  Pod-Log, Garage-500er).
