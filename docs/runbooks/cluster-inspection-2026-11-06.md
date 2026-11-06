# KellerIO-Clusterinspektion vom 06.11.2026

Momentaufnahme vom 06.11.2026, etwa 19:00 UTC, aus dem LAN. Die Inspektion war bis auf
die unten dokumentierte Bereinigung read-only; es wurden keine Secrets ausgelesen. Die
Ergebnisse beschreiben den Prüfzeitraum und sind keine dauerhafte Verfügbarkeitsgarantie.
Hauptbefund: Der Cluster ist unauffällig, der offene Punkt „Backup-Lauf 04.11. prüfen“
aus der Inspektion vom 03.11. ist geschlossen.

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 06.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions |
| ArgoCD | Alle Apps Synced und Healthy | 47 Applications, 46 Synced/Healthy, 1 Progressing: `yealink` (bekannt) |
| Pods | Keine Störungen | Kein Pending-, CrashLoop- oder Failed-Pod, keine Restarts in 48 h |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49 Zertifikate Ready, frühester Ablauf 08.12.2026 |
| Jobs | Keine Fehlschläge | Keine fehlgeschlagenen Jobs; CronJobs `renovate` und `jitmgmt-staging/rechnungslauf` sind suspendiert |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 58 PV / 57 PVC, alle `ceph-rbd` und Bound |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, 0 B zurückgehalten |
| Backups | Täglich erfolgreich | CNPG-Backups vom 04., 05. und 06.11. für alle täglichen Cluster `completed` |

## Alarme (48 h)

- Aktiv sind nur `KubeDeploymentReplicasMismatch` und `KubePodNotReady` (beide `yealink`,
  seit 02.11.) sowie `Watchdog`. Aufgelöst wurde nur `InfoInhibitor` am 05.11.,
  02:45–02:50.
- vmalert: 243 Regeln ohne `lastError`, keine Targets mit `up==0`.
- Grafana auf vizmon01: Es feuert nur `proxceph-health-not-ok` (bekannt,
  `AUTH_INSECURE_*`). Die Gruppe `kellerio-cluster-health` und alle Regeln mit
  `notify=signal` sind normal.

## Speicher

- `du` gegenüber kubelet weicht höchstens um 23 MiB ab (`vmsingle`). Höchste Belegung:
  `mailman-web-data` 54 % (vor der Bereinigung, jetzt 3 %), `vmsingle` 47 %. Inodes
  niedrig.
- Keine statischen, lokalen, hostPath- oder NFS-PVs. Einziges geteiltes Dateisystem ist
  der Inline-SMB-Mount `//192.168.2.75/scanner` (paperless).
- Talos `/var`: wrk1 81 % (7,1 GiB frei, imageFs 28,6 GiB), wrk4 69 %. Image-GC setzt bei
  85 % ein, die Eviction `imagefs.available` bei 15 % frei – das ist dieselbe Schwelle.
  wrk1 beobachten.

## Replikationsslots und WAL

Alle 10 CNPG-Cluster sind 2/2 gesund, haben je einen aktiven physischen Slot mit
`wal_status` `reserved` und 0 B zurückgehalten. `pg_wal` belegt 224–624 MB und liegt unter
`max_wal_size`; der Replay-Lag beträgt höchstens 6 ms. `max_slot_wal_keep_size` steht
weiterhin auf -1.

## Backups

- CNPG-Backups vom 04., 05. und 06.11. sind für alle täglichen Cluster `completed`. Das
  schließt den offenen Punkt „Backup-Lauf 04.11. prüfen“ vom 03.11.; der
  `mdcheck`-Timer-Fix auf `u22` wirkt.
- Die 5 Fehlschläge vom 03.11. und die Archiver-Fehler (`.history`) vom 03.11.
  05:06–05:33 UTC haben sich nicht wiederholt.
- `mastodon-pg` sichert weiterhin nur wöchentlich (zuletzt 01.11.).
- 12 von 12 Offsite-CronJobs liefen heute erfolgreich, 5 MariaDB-CRs laufen.

## Cilium

Der Agent auf wrk2 zeigt ein Working Set von 456 Mi bei 512 Mi Limit (der Vorgänger-Pod
417–452 Mi), aber nur 137 Mi RSS (der niedrigste Wert der verglichenen Agents). Die
Differenz ist Page-Cache und Kernel-Speicher. Keine OOM-Events in 30 Tagen. Reine
Beobachtung; steigt der Wert weiter, das Limit in
`infrastructure/base/cilium/values.yaml` beim nächsten geplanten Cilium-Sync anheben. Der
L2-Lease des Ingress liegt aktuell auf wrk5.

## Weitere Befunde

- **Mastodon-Elasticsearch:** grün, aber 0 Indizes (Suchindex nicht aufgebaut, bekannt).

## In dieser Inspektion behoben

Auf ausdrückliche Freigabe von Ingo wurden drei Reste entfernt:

- **Whoosh-Index im Web-PVC:** `/opt/mailman-web-data/fulltext_index` (9,9 GiB) im Pod
  `mailman-web` gelöscht. Vorher geprüft: `uwsgi.ini` enthält weder `runjobs hourly` noch
  `runjobs monthly`, `HAYSTACK_SIGNAL_PROCESSOR` ist nirgends gesetzt. Belegung des
  Dateisystems von 10,5 GiB (54 %) auf 672 MiB (3 %), frei 9,0 GiB → 18,9 GiB. Pod weiter
  Ready, `postorius/lists/` antwortet mit HTTP 200.
- **PVC `mailman/mailman-web-index-staging`** (100 Gi, nicht in Git, per `kubectl apply`
  angelegt): Kein Pod und kein VolumeAttachment, keine Referenz im Repo. Gelöscht, der PV
  `pvc-7bae7f44-7175-4346-9192-f4d72bf36d67` (reclaimPolicy `Delete`) war danach
  ebenfalls weg.
- **Service `default/cert-manager-webhook-cloudns`:** verwaist, ohne Endpoints und ohne
  ArgoCD-Tracking, kein Manifest im Repo. Der echte Webhook liegt in `cert-manager`. Nach
  dem Löschen ist der APIService `v1alpha1.acme.jit.services` weiter `Available=True`
  (Ziel `cert-manager/cert-manager-webhook-cloudns`), alle 49 Zertifikate sind Ready.

Hinweis: Das Learning-Dokument
[`mailman-whoosh-reindex-performance.md`](../learnings/mailman-whoosh-reindex-performance.md)
hielt am 02.11. fest, Index und Staging-PVC seien gelöscht worden. Beides existierte aber
noch bis zum 06.11.; die Angabe dort ist korrigiert.

## Offene Punkte und Entscheidungen

Unverändert, dies ist keine Löschfreigabe:

- **Verwaiste PVCs:** `authentik/data-authentik-valkey-0`, `kite/kite-storage`,
  `wordpress-3/wordpress` und `wordpress-3/data-wordpress-mariadb-0` (Deployment 0/0
  skaliert) sowie die 4 Retain-VolumeSnapshots vom 31.07./02.08. (mailman-core/-web
  pre-052, paperless-data/-media pre-22015).
- **yealink-App-Passwort:** hält die Alarme und den Status Progressing.
- **`mastodon-pg`:** tägliches Backup statt wöchentlich.
- **`max_slot_wal_keep_size`:** Obergrenze festlegen.
- **Node-Verteilung:** Entlastung von wrk5 und wrk3 planen.
- **Ceph:** `AUTH_INSECURE_*` beheben oder stummschalten.
