# KellerIO-Clusterinspektion vom 11.11.2026

Momentaufnahme vom 11.11.2026, etwa 04:15 UTC, aus dem LAN. Die Inspektion war read-only;
es wurden keine Secrets ausgelesen. Die Ergebnisse beschreiben den Prüfzeitraum und sind
keine dauerhafte Verfügbarkeitsgarantie. Hauptbefund: Der Cluster ist im Soll. Neu sind
ein fehlgeschlagenes CNPG-Basebackup (`goloom`) wegen eines kurzen Garage-Aussetzers und
eine zu knappe Readiness-Probe am NetBox-Server (mit diesem PR behoben).

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 11.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions |
| ArgoCD | Alle Apps Synced und Healthy | 47 Applications, 46 Synced/Healthy, 1 Progressing: `yealink` (bekannt) |
| Pods | Keine Störungen | Kein Pending-, CrashLoop- oder Failed-Pod, keine Restarts in 48 h |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49 Zertifikate Ready, keines läuft in den nächsten 21 Tagen ab, keine offenen Challenges |
| Jobs | Keine Fehlschläge | Keine fehlgeschlagenen Jobs; CronJobs `renovate` und `jitmgmt-staging/rechnungslauf` sind suspendiert |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 57 PV / 57 PVC, alle `ceph-rbd` und Bound; 52 VolumeAttachments ohne Fehler |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, höchstens 15 KB zurückgehalten |
| Backups | Täglich erfolgreich | 9 von 10 CNPG-Clustern aktuell; `goloom-pg` am 11.11. fehlgeschlagen (siehe unten) |
| Notifications | Zustellung ohne Fehler | Alertmanager: 12 Mails in 48 h, 0 Fehlschläge; ArgoCD-Notifications ohne Fehlerzeilen |

Kubernetes-Events reichen nur etwa eine Stunde zurück. Aussagen über 48 h stützen sich
deshalb auf Metriken (`ALERTS`, Restart-Zeitstempel), nicht auf Events.

## Alarme (48 h)

- Cluster-Alertmanager: Aktiv sind nur `KubeDeploymentReplicasMismatch` und
  `KubePodNotReady` (beide `yealink`, seit 02.11.) sowie `Watchdog`. Im Fenster wurde
  nichts aufgelöst außer `InfoInhibitor` (3 Samples). Keine Silences.
- vmalert: 243 Regeln, alle `health=ok`.
- Grafana auf vizmon01 (51 Regeln, alle `health=ok`), feuernd:
  - `kellerIO CNPG base backup failed` für `goloom` seit 11.11. 02:57 UTC (neu),
  - `Ceph health is not OK` seit 08.11. 13:02 UTC,
  - `prometheus.radiotux.de traffic high (24 h)` seit 10.11. 21:29 UTC (323 GiB, kein
    Clusterbezug).
  Die Grafana-API liefert nur den aktuellen Zustand; eine 48-h-Historie wurde dort nicht
  geprüft.

## Speicher

- `du -sxk` gegenüber kubelet weicht höchstens um 14 MiB ab (`vmsingle`, laufende
  Schreiblast). Höchste Belegung: `vmsingle` 49 %, `mastodon-pg` 36 %. Inodes höchstens
  4,1 % (`matomo-data`). Bei linearem Trend wird keine PVC in 30 Tagen voll.
- Nicht messbar: `goloom-data` (Image ohne Shell; kubelet meldet 0,00 GiB).
- Statische lokale PVs auf geteilten Dateisystemen: keine. Alle 57 PVs sind dynamisch per
  `rbd.csi.ceph.com` provisioniert; es gibt keine `local`-, `hostPath`-, NFS- oder
  statischen CSI-PVs und keine CephFS-PVCs. `hostPath` nutzen nur Systemkomponenten
  (ceph-csi, csi-driver-smb, cilium, node-exporter, crowdsec-agent lesend, Control Plane).
  Das API-Server-Audit-Log auf `/var` der Control-Plane-Nodes ist auf rund 1,1 GiB
  begrenzt.
- Talos `/var`: wrk1 80 % (7,4 GiB frei, stabil), wrk4 69 %, wrk2 49 % (−1,5 GiB frei in
  7 Tagen, beobachten).
- `mailman-web-data` fiel zwischen 04.11. und 06.11. von 10,5 auf 0,66 GiB: das ist die
  dokumentierte Löschung des Whoosh-Index vom 06.11.

## Replikationsslots und WAL

Alle 10 CNPG-Cluster sind 2/2 gesund. Je ein aktiver physischer Slot `_cnpg_<cluster>_<n>`
mit `wal_status=reserved`, zurückgehalten 0 B (crowdsec 15 KB), Replay-Lag 0 Byte. Keine
logischen Slots, keine Slots zu nicht mehr vorhandenen Instanzen. `pg_wal` 417–625 MiB,
`archive_status` ohne `.ready`-Dateien. `max_slot_wal_keep_size` steht weiter auf `-1`,
`wal_keep_size` auf 512 MB. MariaDB: fünf Einzelinstanzen ohne Replikation.

## Backups

- CNPG: Alle täglichen Cluster haben ein Basebackup vom 11.11., außer `goloom-pg`.
  `mastodon-pg` sichert wöchentlich (zuletzt 08.11.).
- `goloom-pg-20261111025000` ist `failed`: `barman-cloud-backup` meldete um 02:50:52 UTC
  `Could not connect to the endpoint URL http://192.168.23.21:3900/...`. Gleichzeitig
  scheiterte die WAL-Archivierung bei `mastodon-pg` (02:50:51–02:51:50) und `crowdsec-pg`
  (bis 02:51:59). Garage war also rund 1–2 Minuten nicht erreichbar. Die Archivierung hat
  aufgeholt; der Garage-Host lief durch und loggt in dem Fenster nichts. Der nächste
  geplante Lauf ist am 12.11. 02:50 UTC.
- Dasselbe Muster zeigt `pg_stat_archiver` für den 03.11. gegen 05:00 UTC und den 08.11.
  gegen 13:00 UTC. Die Ursache (vermutlich der Netzpfad Halbe–Potsdam) ist nicht geklärt.
- MariaDB-Backups (kimai, matomo, wordpress-1/-2/-3) vom 11.11. `Success`. Alle
  Offsite-CronJobs liefen im Plan und endeten `Complete`.
- `goloom-backup` (Offsite) meldet `noch kein /data/media` und sichert damit derzeit keine
  Dateien; ob `goloom-data` Schützenswertes enthält, wurde nicht geprüft.

## Behoben mit diesem PR

- **NetBox-Server, Probe-Timeout:** Die Readiness-Probe (`GET /login/`) lief mit dem
  Chart-Default `timeoutSeconds: 1` und schlug seit dem 02.11. 413-mal fehl (rund 48-mal
  pro Tag), obwohl `/login/` in etwa 10 ms antwortet und der Pod nie neu startete. Bei
  jedem Fehlschlag fällt der Pod kurz aus dem Service. Readiness und Liveness stehen jetzt
  auf 5 s (`apps/base/netbox/values.yaml`). Der Rollout ersetzt den Server-Pod
  (`Recreate`), die Oberfläche ist dabei kurz nicht erreichbar.

## Ceph (außerhalb des Clusters, nur gelesen)

`HEALTH_ERR`: die bekannten `AUTH_INSECURE_*`-Meldungen, `MDS_CACHE_OVERSIZED`
(mds.cloud67, 4 GB bei 2 GB Limit), BlueStore-Slow-Ops auf osd.0, osd.1, osd.8 und osd.10,
Stalled Read im DB-Device von osd.10 sowie ein gesetztes `noout`-Flag (Zeitpunkt nicht
ermittelt). Rohkapazität 72,5 % belegt. Um 04:06 UTC fielen ein WAL-Sender-Timeout
(`crowdsec-pg`), ein NetBox-Probe-Timeout und ein Valkey-Ping-Timeout (`paperless`)
zusammen; das lag in der Inspektion selbst (`du` über alle Volumes) und passt zu den
Slow-Ops, ist aber nicht belegt.

## Offene Punkte

- **Garage-Erreichbarkeit:** drei kurze Aussetzer in acht Tagen; Netzpfad Halbe–Potsdam
  prüfen. Bis zum Lauf am 12.11. ist das jüngste `goloom`-Basebackup vom 10.11.
- **Ceph `noout`:** klären, ob das Flag absichtlich gesetzt ist.
- **yealink-App-Passwort:** hält die Alarme und den Status Progressing (unverändert).
- **`max_slot_wal_keep_size`:** Obergrenze festlegen (unverändert).
- **`mastodon-pg`:** Basebackup nur wöchentlich (unverändert).
- **Verwaiste PVCs:** `authentik/data-authentik-valkey-0`, `kite/kite-storage`,
  `wordpress-3/wordpress`, `wordpress-3/data-wordpress-mariadb-0` (unverändert).
- **Ohne Backup:** Mailman-`var/queue`, Dateien von `wordpress-3`, `jitmgmt-fints`,
  `kite-storage` (unverändert).
- **`mastodon/data-mastodon-search-0`:** 10-Gi-Volume praktisch leer; ob die Volltextsuche
  absichtlich unbefüllt ist, wurde nicht geprüft.
