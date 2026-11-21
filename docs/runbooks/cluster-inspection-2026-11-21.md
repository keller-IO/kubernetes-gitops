# KellerIO-Clusterinspektion vom 21.11.2026

Momentaufnahme vom 21.11.2026, etwa 17:00–18:30 UTC. Die Inspektion war read-only;
es wurden keine Secrets ausgegeben. Die Ergebnisse beschreiben den Prüfzeitraum und sind
keine dauerhafte Verfügbarkeitsgarantie. Hauptbefund: Der Cluster ist im Soll, es gibt
keinen Reparaturbedarf. Gegenüber dem 18.11. sind die beiden Failed-Jobs in `jitmgmt`
verschwunden, damit ist `KubeJobFailed` beendet. Der einzige neue Befund liegt außerhalb
des Clusters (Traffic `prometheus.radiotux.de`).

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 21.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions; CPU 7–21 %, RAM 49–66 % |
| ArgoCD | Alle Apps Synced und Healthy | 47/47 Synced/Healthy, keine laufende Operation |
| Pods | Keine Störungen | Keine Restarts, OOM-Kills oder CrashLoops in 48 h; keine Pending-Pods; keine Warning-Events |
| Workloads | ready = desired | Deployments, StatefulSets und DaemonSets vollständig; keine hängenden Rollouts |
| Jobs | Keine Failed-Jobs | Keine; alle CronJobs mit aktuellem `lastSuccessfulTime` |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49/49 Ready, frühester Ablauf 24.12. (`netbird-operator-serving-cert`, Renewal 24.11.); keine offenen Orders/Challenges |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 57/57 PVC Bound (`ceph-rbd`), 52 VolumeAttachments ohne Fehler; keine PVC über 70 % (`vmsingle` 48 %, `mastodon-pg` 36 %) |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, `reserved`, 0 B Rückstand (`mastodon-pg` 14 kB), `.ready` = 0 |
| Backups | Täglich erfolgreich | Alle CNPG-Backups am 21.11. 02:00–02:55 UTC `completed`, Archiv jeweils hinter `endWal`; `mastodon-pg` wöchentlich (15.11.); 12/12 Offsite-CronJobs erfolgreich |
| Notifications | Zustellung ohne Fehler | Alertmanager: 3 Mails in 48 h, 0 Fehlschläge, keine Silences; vmalert ohne Ausführungsfehler |

## Alarme (48 h)

- Aktiv im Cluster: nur `Watchdog` (Route `null`, unverändert).
- Aufgelöst: `KubeJobFailed` (`jitmgmt`) endete am 20.11. gegen 18:10 UTC, weil die Jobs
  `hetzner-import-29914785` und `proxmox-sync-29914785` nicht mehr existieren. Erwartet war
  das Ende erst mit der TTL am 24.11. Wer oder was die Jobs gelöscht hat, ist nicht mehr
  feststellbar; die Logs der Fehlläufe sind damit weg.
- `InfoInhibitor` (`crowdsec`) einmalig am 20.11. 07:25 UTC, zeitgleich mit dem Rollout der
  PHP-Sicherheitsimages und der Renovate-Merges #504/#509/#512/#513 (Pods ab 07:18 UTC neu).
- Scrape-Targets: aktuell keines `up == 0`; in 48 h nur `crowdsec-agent` 10.244.3.53 für
  etwa 1 Minute.
- Grafana vizmon01: firing nur `proxceph-health-not-ok` (Ceph `HEALTH_ERR`, siehe unten) und
  `traffic-prometheus-month-high` (neu, siehe unten). `proxnet-corosync-retransmits` und
  `dns-ext-serial-drift` sind wieder normal. Gruppe `kellerio-cluster-health` inklusive der
  Signal-Regeln komplett normal. Datenquelle `zwave` meldet „database name required“
  (Altlast, nicht kellerIO).
- Die Mastodon-Regeln auf vizmon01 passen bereits zum Cutover: `mastodon-pg` ist seit der
  Promotion kein Replica-Cluster mehr (`spec.replica.enabled: false`), die Replica-Regeln
  stehen in `deleteRules`, und `kellerio-cnpg-backup-stale` hat mit 192 h genug Spielraum für
  das Wochenbackup.

## Speicher

- Verzeichnisbelegung (`du`) gegen kubelet-Metrik: Bei 50 von 51 geprüften PVCs höchstens
  5 MiB Abweichung. Einzige Abweichung über 5 %: `mastodon/mastodon-valkey-data` mit `du`
  178 MiB gegen 208 MiB kubelet (31 MiB), unkritisch. `goloom-data` hat keine Shell, dort gilt
  nur die Metrik (1 MiB).
- Größtes 7-Tage-Wachstum: `mastodon-pg` +72 MiB je Instanz; `vmsingle` −456 MiB.
- Statische lokale PVs auf gemeinsam genutzten Dateisystemen: keine. Kein PV ohne
  `provisioned-by`, kein `spec.local`/`hostPath`/`nfs`, kein statisches CSI-Volume, keine
  `ceph-fs`-PVC. Kein volumeHandle oder RBD-Image doppelt, keine PVC von mehr als einem Pod
  gemountet. hostPath nutzen nur die erwarteten System-DaemonSets sowie `crowdsec-agent`
  (`/var/log`).
- 6 VolumeSnapshots, alle `readyToUse`, keine verwaisten Contents (unverändert).
- Ohne laufenden Pod (unverändert): `authentik/data-authentik-valkey-0`,
  `wordpress-3/data-wordpress-mariadb-0`, `wordpress-3/wordpress` (Deployment auf 0),
  `kite/kite-storage` (nur Job `kite-pg-migrate`). `jitmgmt-fints` gehört zu `bankabgleich`.
- `/var` der Nodes, frei in GiB:

| Node | 21.11. | 18.11. | vor 7 d |
| --- | --- | --- | --- |
| `cp1` | 9,4 | 9,7 | 9,7 |
| `cp2` | 9,2 | 9,5 | 9,5 |
| `cp3` | 9,1 | 9,4 | 9,6 |
| `wrk1` | 20,0 | 22,8 | 23,3 |
| `wrk2` | 9,7 | 13,0 | 13,6 |
| `wrk3` | 20,8 | 21,8 | 21,4 |
| `wrk4` | 10,0 | 11,6 | 11,7 |
| `wrk5` | 10,8 | 12,4 | 14,5 |

  Einordnung: Image-Churn durch die Rollouts vom 20./21.11. (PHP-Images, jitmgmt). Die
  Image-GC greift bei 85 % (etwa 5,7 GiB frei auf Workern), wie am 18.11. auf `wrk1` belegt.
  Beobachten, kein Handlungsbedarf.

## CNPG und Backups

| Cluster | Primary | PG | `max_slot_wal_keep_size` | Jüngstes Backup |
| --- | --- | --- | --- | --- |
| `ciso-assistant-pg` | -2 | 17.2 | 2GB | 21.11. 02:40 |
| `crowdsec-pg` | -2 | 17.11 | 2GB | 21.11. 02:10 |
| `expense-pg` | -2 | 17.11 | 2GB | 21.11. 02:20 |
| `goloom-pg` | -1 | 17.11 | 2GB | 21.11. 02:50 |
| `mailman-pg` | -2 | 16.15 | 8GB | 21.11. 02:00 |
| `mastodon-pg` | -2 | 16.15 | 16GB | 15.11. 02:00 (wöchentlich) |
| `monitoring-pg` | -2 | 17.11 | 2GB | 21.11. 02:30 |
| `netbox-pg` | -2 | 17.11 | 2GB | 21.11. 02:55 |
| `paperless-pg` | -2 | 17.11 | 2GB | 21.11. 02:00 |
| `roundcube-pg` | -2 | 17.2 | 2GB | 21.11. 02:00 |

- Alle Standbys `streaming`/`async`, je 2/2 Instanzen ready, keine Restarts.
- `pg_stat_archiver`: jüngste Fehler stammen aus dem bekannten Fenster 17.11. 03:44–03:47 UTC
  bzw. vom 03.11. (`.history`). In den Instanz-Logs seit 18.11. keine Archivfehler.
- MariaDB: 5/5 CRs Ready; reguläre Sicherung per CronJob aktuell.
- Offsite: Die 0-Objekt-Läufe von `ciso-assistant-evidence-offsite` und
  `netbox-media-offsite` sind korrekt. Beide Quellen sind leer: die PVC `netbox-media`
  enthält nur `lost+found`, der S3-Bucket `ciso-assistant-evidence` hat 0 Objekte. Die Jobs
  sichern erst etwas, sobald dort Daten liegen.

## Ceph

- `HEALTH_ERR` unverändert nur wegen `AUTH_INSECURE_SERVICE_KEY_TYPE`/`_TICKETS`, dazu die
  übrigen `AUTH_INSECURE_*`-Warnungen und `noout` (Absicht).
- `BLUESTORE_SLOW_OP_ALERT` jetzt auf `osd.0`, `osd.1`, `osd.6`, `osd.8`, `osd.10` (neu:
  `osd.6`); `DB_DEVICE_STALLED_READ_ALERT` jetzt auf `osd.1` (am 18.11. `osd.0`).
- `MDS_CACHE_OVERSIZED` (cloud67, 4 GB bei 2 GB Limit) unverändert.
- 9/9 OSDs up/in, 497/497 PGs `active+clean`, Raw 72,8 %, `osd.1` 79,7 % (knapp unter
  nearfull 80 %). Pool `kubernetes` 131 GiB, ohne Quota.
- 5 nicht archivierte Crash-Reports (`osd.6`, `osd.10`, `osd.2`), alle von August/September;
  keiner seit 18.11.

## Außerhalb des Clusters: Traffic `prometheus.radiotux.de`

`traffic-prometheus-month-high` feuert zu Recht. vnstat-TX im November: 1.398 GiB am 17.11.,
dann +212 GiB (18.11.), +301 GiB (19.11.), +149 GiB (20.11.), +53 GiB (21.11. bis etwa
17:30 UTC), zusammen 2.112 GiB. Das Inklusivvolumen entspricht etwa 1.950 GiB vnstat-TX und
ist damit bereits überschritten. Die Applebot-Sperre vom 20.11. wirkt, der Tageswert ist
wieder im Normalbereich. Bei 40–70 GiB je Tag bis Monatsende sind rund 400–600 GiB
Mehrvolumen zu erwarten (0,09 €/GB). Ob die Spitzen am 18./19.11. allein von Applebot kamen,
ist nicht geprüft; die nginx-Logs reichen 14 Tage zurück.

## Offene Punkte

- **Ceph:** Auth-Härtung (`AUTH_INSECURE_*`), Slow-Ops (jetzt auch `osd.6`), `osd.1` nahe
  nearfull, alte Crash-Reports archivieren.
- **Dead-Man-Switch:** `Watchdog` an ein externes Ziel leiten (unverändert).
- **Verwaiste PVCs und alte VolumeSnapshots** (unverändert, Entscheidung Ingo).
- **`ciso-assistant-pg`, `roundcube-pg`:** noch PostgreSQL 17.2.
- **Traffic prometheus:** Spitzen 18./19.11. in den nginx-Logs zuordnen.
- **Failed-Jobs vom 17.11.:** vor der TTL gelöscht, Verursacher unbekannt.
