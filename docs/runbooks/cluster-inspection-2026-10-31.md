# KellerIO-Clusterinspektion vom 31.10.2026

Read-only-Momentaufnahme vom 31.10.2026, etwa 11:00–12:15 UTC. Zugriff erfolgte
über die freigegebene Kubernetes-API und die Metrik-Abfrage; Datenbankabfragen
waren ausschließlich `SELECT`. Es wurden keine Ressourcen geändert und keine
Secrets ausgelesen. Die Ergebnisse beschreiben den Prüfzeitraum und sind keine
dauerhafte Kapazitäts- oder Verfügbarkeitsgarantie. Der Befund zu ingress-nginx
wird durch denselben PR behoben (Memory-Limit 512Mi).

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 31.10.2026 |
| --- | --- | --- |
| ArgoCD und Workloads | Verwaltete Apps und Controller bereit | 46/46 Applications Synced und Healthy, keine ausstehenden Operationen; alle Deployments, StatefulSets und DaemonSets bereit; kein Pending-, CrashLoop-, ImagePull- oder Terminating-Pod |
| Nodes | Alle Nodes Ready ohne Druck | 8/8 Nodes Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49 Zertifikate Ready, keines läuft innerhalb von 21 Tagen ab; keine Objekte mit hängendem `deletionTimestamp` |
| ingress-nginx | Keine OOMKills | 4 von 8 Controller-Pods OOMKilled (Befund, behoben durch diesen PR) |
| Kapazität | Requests mit Reserve | `kellerio-wrk3` bei 96 % Memory-Requests (Planungshinweis) |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 58 PVCs / 58 PVs Bound, alle Ceph RBD CSI |
| PostgreSQL | CNPG-Cluster und Slots gesund | 10 Cluster, je 2/2 Instanzen, streamend, 0 B zurückgehaltenes WAL |
| Backups | Täglich erfolgreich | 9 Cluster täglich OK; Mastodon nur wöchentlich (Entscheidung offen) |
| Alarmierung | Kritische Alarme erreichen einen Empfänger | In-Cluster-vmalertmanager nur mit `null`-Empfänger, alle 243 vmalert-Regeln still |

## ingress-nginx: OOMKills (behoben durch diesen PR)

Vier der acht Controller-Pods wurden innerhalb von vier Tagen mit dem Limit von
256Mi OOMKilled; über 30 Tage gab es 30 Container-Restarts im Namespace
`ingress-nginx`.

| Node | Letzter OOMKill (UTC) |
| --- | --- |
| kellerio-wrk5 | 27.10. 14:29 |
| kellerio-wrk3 | 29.10. 14:39 |
| kellerio-wrk2 | 29.10. 15:40 |
| kellerio-cp3 | 30.10. 13:01 |

Maximales Working Set über 7 Tage (`container_memory_working_set_bytes`, kellerIO
VictoriaMetrics): gekillte Pods 225–255Mi, gesunde Pods 76–162Mi, aktueller
Normalbetrieb 55–195Mi. Wahrscheinliche Ursache sind Speicherspitzen bei
Config-Reloads (alte nginx-Worker laufen neben den neuen weiter) bei rund 57 Hosts
und 49 Zertifikaten; der Normalbetrieb passt in den 128Mi-Request.

Änderung: `controller.resources.limits.memory` 256Mi → 512Mi in
`infrastructure/base/ingress-nginx/values.yaml`. Der Request bleibt bei 128Mi,
weil `kellerio-wrk3` bei 96 % Memory-Requests steht. Rollout: Das DaemonSet
(RollingUpdate, `maxUnavailable=1`, `maxSurge=0`) startet die acht Controller
nacheinander neu. Mit `externalTrafficPolicy: Local` verliert ein Node kurz seinen
Verkehrsanteil, solange sein Pod neu startet. Nach dem Rollout prüfen, ob weitere
OOMKills ausbleiben.

## Kapazität

`kellerio-wrk3` hat Memory-Requests von 11076Mi (96 %) und Limits von 202 %; die
übrigen Worker liegen bei 49–79 % Requests. Die tatsächliche Nutzung liegt bei
33–73 %. Das ist ein Hinweis zur Kapazitätsplanung; es wurde nichts geändert.

## Neustartwelle am 31.10. 00:11–00:12 UTC

Gleichzeitig starteten neu: ceph-csi-Provisioner (rbd, cephfs), cnpg-controller,
csi-smb-controller, snapshot-controller, system-upgrade-controller, der
kube-controller-manager auf cp3 und ein node-exporter. Das spricht für
Leader-Election-Verlust, wahrscheinlich durch einen kurzen Stillstand von API oder
etcd. Die Ursache ist offen; auf Wiederholung achten.

## Speicher

58 PVCs und 58 PVs waren Bound, alle Ceph RBD CSI. Es gibt keine statischen,
lokalen, hostPath-, CephFS- oder SMB-PVs. Die Kubelet-Volume-Metriken stimmen mit
echtem `du` für die gemessenen PVCs überein (`mailman-web-data` maximal 54 %,
`vmsingle` 45 %, `mastodon-pg-1` 36 %).

Das einzige gemeinsame Dateisystem ist das Inline-SMB-CSI-Volume
`//192.168.2.75/scanner` im Paperless-Pod. Dafür gibt es keine Kubelet-Metrik;
`df` zeigt das gesamte NAS (28,5 TB, 85 % belegt, 4,35 TB frei), der Inhalt des
Shares umfasst 0,4 GB.

Die StorageClass `ceph-fs` hat den Provisioner `cephfs.csi.ceph.com`; die frühere
Annahme „kein Provisioner“ ist veraltet. Sie wird derzeit nicht genutzt.

| Namespace / PVC | Kapazität | Einordnung |
| --- | ---: | --- |
| mailman / `mailman-web-index-staging` | 100 Gi | Bewusst behalten |
| forgejo / `gitea-shared-storage` | 20 Gi | Deployment 0/0 |
| wordpress-3 / `wordpress` | 5 Gi | Skaliert auf 0 |
| wordpress-3 / `data-wordpress-mariadb-0` | 8 Gi | Rest des alten Chart-Layouts; das StatefulSet nutzt `storage-wordpress-mariadb-0` |
| authentik / `data-authentik-valkey-0` | 1 Gi | App entfernt |

Vier VolumeSnapshots (mailman-core, mailman-web, paperless-data, paperless-media)
stammen vom 31.07./02.08., haben die Retain-Policy und sind ready. Es sind
Pre-Upgrade-Snapshots, die freigegeben werden könnten. Das ist eine
Bestandsaufnahme und keine Löschfreigabe.

## PostgreSQL (CNPG)

Zehn Cluster, je 2/2 Instanzen bereit, Replicas streamen. Alle zehn
Replikations-Slots `_cnpg_<cluster>_<n>` sind physisch, aktiv, `wal_status`
`reserved` und halten 0 B zurück. Es gibt keine logischen Slots; `pg_wal`
belegt 129–625 MB auf dem Daten-PVC; keine Transaktion läuft länger als eine
Stunde.

| Cluster | Slot |
| --- | --- |
| ciso-assistant-pg | `_cnpg_ciso_assistant_pg_<n>` |
| crowdsec-pg | `_cnpg_crowdsec_pg_<n>` |
| expense-pg | `_cnpg_expense_pg_<n>` |
| forgejo-pg | `_cnpg_forgejo_pg_<n>` |
| goloom-pg | `_cnpg_goloom_pg_<n>` |
| mailman-pg | `_cnpg_mailman_pg_<n>` |
| mastodon-pg | `_cnpg_mastodon_pg_<n>` |
| monitoring-pg | `_cnpg_monitoring_pg_<n>` |
| paperless-pg | `_cnpg_paperless_pg_<n>` |
| roundcube-pg | `_cnpg_roundcube_pg_<n>` |

`pg_stat_archiver.last_archived_time` ist auf ruhigen Clustern alt (forgejo
19.10., expense 21.10., ciso-assistant 23.10.), während `ContinuousArchiving=True`
gilt und die täglichen Backups abschließen. Die Statistik ist nach Neustarts
unzuverlässig und kein Fehler.

## Backups

- Neun CNPG-Cluster sichern täglich; letzter Erfolg jeweils am 31.10. zwischen
  02:00 und 02:50 Uhr.
- `mastodon-pg` sichert nur **wöchentlich** (`0 0 2 * * 0`, zuletzt 25.10.) bei
  23 GB Daten. Offen ist die Entscheidung, auf täglich umzustellen
  (`apps/base/mastodon/backup.yaml`).
- `mailman-pg` schlug am 26.10. (und 18.10.) fehl; täglich wieder OK seit 27.10.
- MariaDB (kimai, matomo, wordpress-1/2/3) und die Offsite-Jobs liefen am 31.10. OK.

## Alarmierung

Der In-Cluster-vmalertmanager hat nur den Empfänger `null`; damit sind alle 243
vmalert-Regeln stumm, auch `KubePersistentVolumeFillingUp`, `KubePodCrashLooping`
und `KubeJobFailed`. Still feuern derzeit `KubeJobFailed` für:

| Namespace / Job | Stand |
| --- | --- |
| jitmgmt / `hetzner-import-29887995` und `-29888010` | 29.10. |
| mastodon / `mastodon-media-remove-29885910` | 28.10., DeadlineExceeded, spätere Läufe OK |
| paperless-ngx / `paperless-watchdog-29880345` | 24.10., TimeoutError |
| mailman / `mailman-web-index-merge-persistent-20260801` | seit 01.08. |

Es gibt keine Grafana-Regel für ArgoCD-Degraded, Zertifikatsablauf in cert-manager
oder CrashLoop/hängende Rollouts.

Grafana (vizmon01): 36 Regeln mit Health `ok`. Feuernd waren die Ceph-Regeln
(osd.2 auf pve ist up, aber `out` mit Gewicht 0, absichtlich geleert; dazu
BlueStore-Slow-Ops und Warnungen zu unsicherer Authentifizierung, insgesamt
HEALTH_ERR) sowie `proxnode-swap-high` (cloud61, 7,4 von 8 GiB Swap).
`proxnode-report-stale` flappte für lat7440, pve2 und cloud67 unterhalb seines
`for`-Fensters. Die Grafana-Datenquelle `zwave` ist unhealthy („database name
required“), `openhab` ist leer.

## Probe-Warnungen und Reste

- `paperless-valkey-0`: Readiness `valkey-cli ping` läuft in den 1-s-Timeout
  (86 Fehler in 11 Tagen, keine Neustarts).
- `eurooffice`: Liveness `/healthcheck` mit „deadline exceeded“ (31 Mal).
- Pod `kimai-mariadb-metrics-847464d859-tsbfw` steht seit 12 Tagen im Status
  Error; das ReplicaSet hat bereits einen laufenden Ersatz.

## Offene Empfehlungen (nicht umgesetzt, Entscheidung nötig)

- vmalert-Criticals an einen echten Empfänger oder nach Grafana leiten.
- Mastodon-Backup auf täglich umstellen.
- Fehlgeschlagene Jobs bereinigen, alte VolumeSnapshots freigeben und Rest-PVCs
  aufräumen.
- Probe-Timeouts für valkey und eurooffice erhöhen.
- Die Neustartwelle von 00:11 UTC beobachten und die Ursache klären.
