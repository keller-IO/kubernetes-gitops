# Restore-Klon im Cluster zieht das Backup über VPN und WAN2

Stand 25.10.2026. Vorfall am 24.10.2026 bei der Messung der Mastodon-4.7-Migrationen.

## Symptom

Um etwa 05:15 UTC entstand im Cluster `mastodon-pg-klon`, ein CNPG-Cluster mit
`bootstrap.recovery` aus `s3://backup-mastodon/cnpg/` auf Garage
(`garage-s3-potsdam`, 192.168.23.21). Bis 05:49 kopierte er das Basis-Backup
`backup-20261022043655` (24,7 GB), danach spielte er WAL ein.

- Ab etwa 05:29 gab es einzelne externe Fehler, ab 05:43 fielen alle Dienste
  auf **185.89.37.138** aus. Das ist WAN2 (`eth7` an der UDM, InternetNord).
- Ceph stand gleichzeitig auf `HEALTH_ERR` mit langsamen BlueStore-Operationen
  (`osd.6` 127 ms), ein OSD startete neu.
- Gegen 06:00 wurde der Klon gelöscht, der Ausfall blieb trotzdem. Zurück kamen
  die Dienste erst, als die Namen auf die Telekom-Leitung (87.191.135.42)
  umgestellt waren: `halbe` und `mail` auf dns01, jit.social bei Cloudflare.

Am 25.10. um 05:20 UTC war 185.89.37.138 von außen noch immer nicht erreichbar
(Test aus Potsdam: HTTPS-Timeout, kein Ping).

## Mechanismus

- Garage steht in Potsdam, der Cluster in Halbe. Jeder Restore aus Garage lädt
  das komplette Basis-Backup und das WAL über die IPsec-Strecke Halbe↔Potsdam
  (`vti66`). Sie lief laut `README_telekom_ausfall_2026-09-24.md` noch über
  WAN2. Ein Restore ist eine einzige große Übertragung ohne Drosselung.
- Der Klon schreibt dabei 25 GB und mehr auf `ceph-rbd`, während die Produktion
  läuft. Der Neustart des OSDs und die langsamen Operationen fallen in diese
  Zeit.
- **Nicht bewiesen** ist, dass der Klon WAN2 lahmgelegt hat. Ein voller Link
  erholt sich, wenn die Übertragung endet. WAN2 war aber auch einen Tag nach dem
  Löschen noch tot. Möglich ist, dass WAN2 zufällig zur selben Zeit ausfiel oder
  dass die Last einen Fehler an UDM oder Anschluss ausgelöst hat, der bestehen
  bleibt. Das ist offen (PRODUCTION-READINESS, Abschnitt 4).
- Dass ein Ausfall von WAN2 alles mitreißt, liegt an der Verteilung: Alle
  öffentlichen Namen hingen an einer Leitung, und `halbe` hatte eine TTL von
  10.400 s. Resolver wie der von Gatus hielten die alte Adresse noch Stunden
  nach der Umstellung.

## Korrektur

- `halbe` (TTL jetzt 300) und `mail` auf dns01 zeigen auf 87.191.135.42,
  jit.social bei Cloudflare ebenso. Backups der Zonen liegen auf dns01 unter
  `/etc/bind/dom/*.bak-{halbe,mail}-telekom-*`.
- Die Migrationsmessung läuft jetzt außerhalb des Clusters, auf einem
  Wegwerf-LXC neben Garage (CT 8031 `mastodon-klon` auf u22):
  [`scripts/ops/mastodon-klon-messung.sh`](../../scripts/ops/mastodon-klon-messung.sh),
  Ablauf im [Runbook](../runbooks/mastodon-migration.md). Am 25.10. lud er das
  Basis-Backup im LAN in 116 s und spielte das WAL in 33 s ein. Dabei war weder
  das VPN noch Ceph beteiligt.

## Prävention

- Keine Restore-Klone im Cluster zum Testen oder Messen. Dafür gibt es das
  Skript in Potsdam.
- `guardrails.sh` lehnt CNPG-Cluster mit `bootstrap.recovery` ab, die Garage
  lesen. Ein echter Restore, etwa der geplante DR-Overlay, braucht in der Datei
  den Kommentar `guardrails: allow-garage-restore` und einen Plan für die
  Leitung: welche WAN, außerhalb der Arbeitszeit, Dienste vorher auf die andere
  Leitung legen.
- Auch u22 hat Grenzen. Beim Entpacken stieg die Last dort auf 16 bei 4 Kernen
  (I/O-Druck 50 %), gleichzeitig liefen PBS und Garage. Das Skript begrenzt die
  Postgres-Container deshalb auf 2 CPUs (`KLON_CPUS`).
