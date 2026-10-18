# Talos-Autoupdate: Live-Abnahme vom 18.10.2026

Keller-main wurde ueber `~/.kube/keller.yaml`, Kontext `keller-main`, mit
Kubernetes-GETs und Metrikabfragen untersucht. Keine Clusterressourcen wurden
veraendert; keine Secret-Inhalte, Exec-Sessions oder Node-Neustarts verwendet.
Diese Zahlen sind eine Momentaufnahme, keine dauerhafte Kapazitaetsgarantie.

## Bestaetigte Voraussetzungen

- Acht Nodes sind `Ready`: drei Control-Planes und fuenf Worker. Alle melden
  Talos **v1.13.4** und Kubernetes **v1.36.0**. Der Drain-Client im PR ist auf
  das verifizierte Registry-Image `rancher/kubectl:v1.36.0` angepasst.
- 65 Deployments, 15 StatefulSets und acht DaemonSets melden ihre gewuenschten
  Replicas bereit; bei der Pod-Pruefung gab es keine unbereiten aktiven Pods.
  CISO Assistant und Roundcube fehlen allerdings aussagekraeftige
  Application-Readiness-Probes. Kubernetes-Ready beweist dort keine HTTP-Recovery.
- 45 PVCs sind Bound, die beobachteten PVs sind Ceph-RBD/RWO ohne harte
  Node-Bindung, lokale Volumes oder HostPath. Alle 39 VolumeAttachments sind
  attached und ohne Attach-Fehler. Das beweist kein funktionierendes Datei-I/O
  und keine freie Kapazitaet im externen Ceph-Pool.
- Aktive Anwendungen mit PVC-Deployment verwenden `Recreate`. Der alte
  Forgejo-Deployment mit RollingUpdate ist auf null Replicas gesetzt.
- Der einzige fail-closed CREATE-Pod-Webhook ist NetBird. Sein Selector
  verlangt `netbird.io/webhook=enabled`; kein Namespace traegt dieses Label,
  insbesondere nicht `kube-system`. Die CNPG-Webhooks betreffen dessen CRs.
- Der gefetchte IaC-Ref `keller-IO/infrastructure`, `keller/main` bei `685f5d9`,
  nennt dieselben acht Nodes, 6-GiB-Control-Planes, vier 8-GiB-Worker und einen
  12-GiB-Worker. Talos v1.13.4, Plattform nocloud und Schematic
  `3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5` stimmen mit
  dem Plan ueberein. Der Factory-Schematic-GET bestaetigt `nfs-utils` und
  `qemu-guest-agent`. Welche Erweiterungen die laufenden Nodes tatsaechlich
  geladen haben, bleibt bis zur Talos-API-Pruefung offen. Der lokale IaC-Branch
  liegt 31 Commits zurueck und ist fuer diesen Vergleich nicht massgeblich.
- SUC und der Talos-Plan aus diesem PR sind noch nicht im Cluster installiert.

## Wartungszustand und Kapazitaet

`kellerio-wrk4` ist seit `2026-10-18T06:18:01Z` cordoned, obwohl der Node Ready
ist und noch 25 Pods betreibt. Darunter laufen einzelne Plattform-Controller.
Die Absicht dieser Wartung muss vor jedem weiteren Node-Update geklaert werden.
Der Prepare-Check haelt deswegen weiterhin an; es erfolgte kein Uncordon.

Requests beruecksichtigen aktive Pods, Init-Container und Pod-Overhead.
RAM in MiB, CPU in Millicores; Nutzung ist eine einzelne Metrikprobe.

| Node | Allocatable CPU / RAM | Requests CPU / RAM | Nutzung CPU / RAM |
| --- | ---: | ---: | ---: |
| cp1 | 1950 / 5292 | 550 / 1404 | 318 / 2755 |
| cp2 | 1950 / 5292 | 690 / 1554 | 423 / 3636 |
| cp3 | 1950 / 5292 | 550 / 1404 | 178 / 2621 |
| wrk1 | 3950 / 7436 | 1820 / 5788 | 274 / 4173 |
| wrk2 | 3950 / 7436 | 1825 / 4660 | 465 / 4149 |
| wrk3 | 3950 / 7436 | 1800 / 5452 | 465 / 4178 |
| wrk4 (cordoned) | 3950 / 7436 | 1340 / 3510 | 219 / 3075 |
| wrk5 | 3950 / 11456 | 2170 / 6407 | 504 / 4782 |

Die Worker belegen zusammen **8955m CPU / 25817 MiB RAM** an Requests.
Alle neun PostgreSQL-Cluster auf drei Instanzen zu erhoehen, braucht zusaetzlich
**2600m CPU / 6656 MiB RAM / 268 GiB logischen PVC-Speicher**. Daraus werden
**11555m CPU / 32473 MiB RAM**; die Ceph-Replikation ist noch nicht eingerechnet.

| Szenario | Verbleibende allocatable CPU / RAM | Folge fuer DB-HA3 |
| --- | ---: | --- |
| Alle fuenf Worker verfuegbar, groesster Worker faellt weg | 15800m / 29742 MiB | 2731 MiB RAM fehlen, noch ohne Reserve |
| wrk4 weiter cordoned, groesster verfuegbarer Worker faellt weg | 11850m / 22307 MiB | 10166 MiB RAM fehlen; CPU bereits rund 97,5 % belegt |

Mit 20 % Request-Reserve muessen die nach Verlust des groessten verfuegbaren
Workers uebrigen schedulable Worker zusammen mindestens **14444m CPU und
40592 MiB allocatable RAM** bereitstellen. Das ist eine konservative Untergrenze;
der Verlust von DaemonSet-Requests wurde nicht abgezogen, Topologie und einzelne
Pod-Groessen sind zusaetzlich zu pruefen. Wenn alle bisherigen fuenf Worker
wieder schedulable sind, wuerden rechnerisch zwei weitere Worker mit jeweils
mindestens 3950m / 7436 MiB allocatable die N-1-Summe auf 23700m / 44614 MiB
bringen und diese 20-%-Untergrenze erfuellen. Das ist eine Dimensionierung fuer
CNPG-HA, keine automatische Provisionierung oder Ceph-Abnahme.
Bei Aenderung der Node-Groessen den
groessten Ausfall neu bestimmen. Requests nicht anhand einer einzigen
Nutzungsprobe heruntersetzen. Keine HA-Replica-Erhoehung ist in diesem PR
enthalten, solange diese Kapazitaet und der externe Ceph-Pool nicht belegt sind.

## Datenbanken und Backups

Neun CNPG-Cluster laufen mit jeweils einer gesunden Instanz, bevorzugter
Anti-Affinity und `failoverDelay: 0`. Jeder Primary-PDB hat
`minAvailable: 1`, `disruptionsAllowed: 0`: ein Worker mit einem solchen Primary
kann ohne HA-Umstellung nicht regulär drainiert werden. Der Authentik-CR im
Git-Bestand ist nicht live und darf nicht als zehntes aktives System gezaehlt werden.

| Namespace / Cluster | Primary auf | Requests CPU / RAM | PVC |
| --- | --- | ---: | ---: |
| ciso-assistant / ciso-assistant-pg | wrk3 | 100m / 256 MiB | 5 GiB |
| crowdsec / crowdsec-pg | wrk1 | 100m / 256 MiB | 5 GiB |
| expense-tracker / expense-pg | wrk1 | 100m / 256 MiB | 5 GiB |
| forgejo / forgejo-pg | wrk1 | 100m / 256 MiB | 10 GiB |
| goloom / goloom-pg | wrk5 | 100m / 256 MiB | 5 GiB |
| mailman / mailman-pg | wrk3 | 100m / 256 MiB | 30 GiB |
| mastodon / mastodon-pg | wrk5 | 500m / 1024 MiB | 64 GiB |
| paperless-ngx / paperless-pg | wrk1 | 100m / 256 MiB | 5 GiB |
| roundcube / roundcube-pg | wrk1 | 100m / 512 MiB | 5 GiB |

Die fuenf MariaDB-Cluster fuer Kimai, Matomo und WordPress 1 bis 3 sind Ready,
laufen aber ebenfalls einzeln ohne Galera. Sie bleiben bei Worker-Drains
Unterbrechungsrisiken, auch wenn PostgreSQL spaeter HA erhaelt.

Zwei PostgreSQL-Backups sind explizit **nicht abgenommen**:

- Mailman: `mailman-pg-20261018020000` failed (`exit status 1`), letzter
  abgeschlossener Backup-CR vom **17.10.2026, 02:07:47 UTC**.
- Mastodon: `mastodon-pg-reseed-20261018` failed (`exit status 1`), letzter
  abgeschlossener Backup-CR vom **24.09.2026, 02:36:11 UTC**.
- Beide Cluster melden `LastBackupSucceeded=False`, obwohl
  `status.lastSuccessfulBackup` einen neueren Zeitpunkt nennt. Ein Zeitstempel
  allein ist kein Erfolgsbeleg: einen neuen completed Backup-CR, konsistente
  Conditions und Restore-Nachweis verlangen. Die anderen sieben Cluster haben
  completed Backup-CRs vom Prueftag; deren Restore wurde hier nicht getestet.

## Konkrete Drain-Blocker und gestufte Freigabe

- **cp1 und cp3:** keine normalen zu evictenden Workload-Pods bei der Pruefung.
  Nach Ende der vorhandenen Wartung und Talos-mTLS-Abnahme sind das die
  kleinsten Canary-Kandidaten. Die Worker-Datenbanken muessen dafuer nicht
  pauschal skaliert werden, da keine ihrer Instanzen auf Control-Planes laeuft.
- **cp2:** CoreDNS und SMB-CSI-Controller. Das `socket-dir` des SMB-Controllers
  unter `/csi` ist ein temporaerer Unix-Socket, blockiert aber die aktuell
  konservative `deleteEmptydirData: false`-Policy. Vor Freigabe dessen Umgang
  pruefen oder den Controller ueber GitOps auf einen anderen Node verlagern.
- **Worker:** CNPG-Singletons/PDBs, Kapazitaet und zahlreiche `emptyDir`-Volumes.
  `vmagent` puffert Metriken in `persistent-queue-data`; Alertmanager haelt
  Zustand wie Silences ohne Persistence. Das ist kein pauschal wegwerfbarer
  Scratch-Speicher. Beide liegen derzeit auf wrk5. Persistence oder akzeptierten
  Datenverlust explizit festlegen, bevor eine geaenderte Drain-Policy ausrollt.

Der Prepare-Check untersucht diese Blocker jetzt auf dem konkreten Zielnode
**vor** dem Cordoning. Normale aktive Jobs werden dabei mitgeprueft, waehrend
SUC-Pods mit `upgrade.cattle.io/controller` wie im nativen Drain ausgenommen sind.
Die globale Recovery-Pruefung bleibt aktiv: alle Nodes und Workloads gesund,
alle CNPG-Replicas Ready und kein offener Switchover. Nur die HA-/Streuungsregel
gilt fuer Datenbanken mit einer Instanz auf dem Zielnode. Ein fehlgeschlagenes
Backup einer betroffenen Datenbank blockiert ebenfalls.

Die geaenderten Regeln wurden zusaetzlich mit Live-GET-Snapshots offline
ausgefuehrt. Da SUC noch fehlt, wird allein fuer diese reine Funktionspruefung
der vorgeschlagene Plan eingesetzt; das ist kein bestandener SUC-Job und kein
Nachweis fuer einen echten Drain/Reboot.

## Noch erforderliche menschliche/operative Abnahme

1. Grund und Abschluss der bereits laufenden Wartung auf wrk4 klaeren.
2. Talos-Credential/CA/Rolle und TCP/50000 **aus dem kuenftigen Jobnetz** pruefen.
   Der Laptop erreichte keinen der acht internen Node-Endpunkte auf TCP/50000.
   Das beweist keine In-Cluster-Sperre; es wurde kein Test-Pod gestartet.
   Installer-Schematic/Erweiterungen und etcd-Zustand brauchen diese Talos-Pruefung.
3. Danach eine Control-Plane-Canary freigeben und echten Reboot/Recovery abnehmen.
   Kein Node ist durch diesen PR neu freigegeben.
4. Worker-Kapazitaet/Ceph nachweisen, DB-HA und Backup-Recovery in getrennten
   Schritten umsetzen, `emptyDir`-Policy konkret abnehmen; erst dann Worker aktivieren.

Verfahren und Notfallablauf: [Talos-Runbook](talos-autoupdate.md).
