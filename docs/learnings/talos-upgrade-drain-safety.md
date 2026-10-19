# Talos: Homelab-Learnings auf keller-main uebertragen

Analyse vom 18.10.2026. Quelle ist `kreativmonkey/homelab-gitops`, letzter Stand
vor Entfernung von SUC: `e0cec723c77b7bb53652659cfd871dced20c1fab`.
Commit `cb285ef9ed32030c258121072e6f83d6f8a565f2` entfernte SUC am 15.10. zugunsten
von Omni. Primaere Belege dort: `docs/learnings/talos-automatic-upgrade-suc-auth.md`,
`talos-autonomous-upgrade-handbook.md`, `cnpg-failover-storm-soft-antiaffinity.md`
und `goloom-rwo-upgrade-race.md`. Die frueheren Fehlkonfigurationen werden
ausdruecklich nicht als Vorlage uebernommen.

| Erfahrung | Umsetzung / Grenze bei keller-main |
| --- | --- |
| `--insecure` funktioniert nur im Maintenance-Mode; Unix-Socket erzeugt TLS-Namensfehler | mTLS-Secret, explizite Node-IP fuer `-e` und `-n`; Authentifizierung vor Aktivierung separat pruefen |
| Controller-Anti-Affinitaet selektierte die eigenen Upgrade-Jobs | Separate App-Labels; Anti-Affinitaet nur fuer Component `controller`; kein `exclusive` |
| Nicht veroeffentlichter Image-Tag wurde durch Cache verdeckt | Manifest-Ref und Image beide SUC v0.20.2; reale Registry-Inspection bei Implementierung; CI prueft Gleichheit |
| Naechster Drain begann vor Replica-/Storage-Recovery | Ein gemeinsamer Plan mit `concurrency: 1`, 5 Minuten Pause, zusaetzlich 60 Sekunden fortlaufend gesundes Prepare |
| Nur ein Standby war gerade selbst im Restart; CNPG fand einmalig keinen Kandidaten | Gate verlangt >=2 Instanzen (bis 19.10.2026: >=3), harte Streuung, aktive PDBs, alle Replicas Ready und abgeschlossenen Switchover; der naechste Drain wartet, bis die evictete Instanz wieder Ready ist |
| Singletons blockieren den Primary-Drain | Im Git-Stand vorhanden; Aktivierung bleibt blockiert. Erst Kapazitaet messen und HA separat ausrollen; keine PDB-Abschaltung als Abkuerzung |
| Zwei Instanzen desselben Clusters auf einem Node verursachten Failover-Sturm | Harte Anti-Affinitaet ist Prepare-Voraussetzung, `failoverDelay: 30` ist Teil der Abnahme |
| CNPG vertagt Reconciliation bei Primary auf cordoned Node | Recovery: Updater und laufenden Job anhalten, Zustand pruefen, dann kontrolliert uncordonen; keine blinde PVC-Loeschung |
| Fail-closed Webhook verhinderte CNI-Neuerstellung | Live-Selectorpruefung fuer `kube-system`; vorhandenes NetBird-Injection-Opt-in beibehalten; HA-Backends bei echten Admission-Gates pruefen |
| DaemonSet-Backoff lief nach Webhook-Reparatur noch 15 Minuten weiter | Fristen und Runbook beruecksichtigen Recovery-Zeit; keine hektischen Pod-Loeschungen |
| RWO-RollingUpdate erzeugte Multi-Attach; 502 hatte keine bereiten Backends | Single-Writer-/Recreate-Abnahme, Pod-Readiness-Gate; CSI und Endpoints pruefen |
| Node-lokale PVs und fehlende Requests-Kapazitaet verhinderten Scheduling | N-1-/node-lokale Kapazitaet vor Freigabe nachweisen; Shared-Ceph nicht als automatisch funktionierend annehmen |
| `Running` mit `0/1` wurde als gesund gezaehlt | Ready-Conditions und gewuenschte/bereite Workload-Replicas pruefen, nicht Status-String allein |
| Mutable Images wurden erst beim Reboot ungeplant aktualisiert | Bestehende `latest`-/`Always`-Guardrails; auch SUC-Job-PullPolicy fest auf IfNotPresent |
| Proxmox-Hardwareaenderungen bleiben nach Guest-Reboot pending | CPU/RAM separat per kontrolliertem Stop/Start abnehmen; kein Nebenprodukt eines Talos-Upgrades |
| Parallel zustaendige Updater und Bootstrap-Konfiguration drifteten | Hier SUC fuer OS-Rollouts, OpenTofu fuer Provisionierung; Omni nicht parallel einfuehren; Versionen vor spaeterem IaC-Apply abgleichen |
| SUC-Job meldet vor dem eigentlichen Reboot Erfolg | Prepare prueft bereits markierte Nodes auf echte Zielversion; letzter Node braucht getrennten Postflight |

Das Homelab setzte historisch `force: true` und `deleteLocalData: true`.
`force` bedeutet bei `kubectl drain` nicht PDB-Bypass, erlaubt aber unmanaged
Pods; `deleteLocalData` erlaubt das Verwerfen von `emptyDir`. Beides wird hier
vorsorglich deaktiviert. Ein dadurch blockierter Drain ist zu analysieren,
nicht durch pauschales Umgehen der Schutzmechanismen aufzuloesen.

## Live-Abnahme und Korrekturen am 18.10.2026

Der [Live-Audit](../runbooks/talos-live-audit-2026-10-18.md) bestaetigte die
Versionen und neun aktive CNPG-Singletons. Er widerlegte die Annahme, dass alle
Datenbanken vor **jedem** Node-Update HA3 brauchen: keine Instanz laeuft auf einer
Control-Plane. HA und harte Streuung werden deshalb nur fuer Cluster geprueft,
deren Instanz der konkrete Drain betrifft. Alle DBs muessen weiterhin global
gesund sein. Eine schon vorhandene Wartung (wrk4 cordoned) blockiert weiter.

**Korrektur 19.10.2026:** Eine Live-Simulation des Preflights ergab, dass mit
`deleteEmptydirData: false` jeder Worker und cp2 vor dem Cordon blockieren
(tmp, CSI-Sockets, CNPG `scratch-data`/`shm`). Die Option ist deshalb an; die
folgende Pruefung greift nur noch, falls sie wieder abgeschaltet wird.

`deleteEmptydirData: false` verhindert Datenverlust, kann aber selbst
Standard-Pods mit `/tmp` oder CSI-Unix-Sockets nicht drainieren. Allein der
native Fehler ist zu spaet: der Node ist dann bereits cordoned. Prepare prueft
deshalb Zielnode-Pods vor dem Cordoning auf unmanaged Pods und blockierende
`emptyDir`-Volumes. Das muss die native SUC-Auswahl respektieren: alle Pods mit
`upgrade.cattle.io/controller` sind vom Drain ausgenommen, sonst blockiert das
`/tmp` des eigenen Controllers dessen Node. Normale Jobs sind nicht pauschal
ausgenommen; auch Backup-/Migrationsjobs koennen `emptyDir` verwenden.

Bei Mailman/Mastodon widersprachen neuere `lastSuccessfulBackup`-Zeitstempel
dem fehlgeschlagenen Backup-CR und `LastBackupSucceeded=False`. Prepare lehnt
einen Drain mit betroffener Datenbank bei explizit fehlgeschlagenem letztem
Backup ab. Ein completed Backup plus Restore-Abnahme bleibt eine separate
Voraussetzung; ein einzelner Status-Zeitstempel ist kein Beleg fuer Recovery.

Diese Muster sind in den Tests abgesichert: CP ohne DB darf gesunde Worker-
Singletons unveraendert lassen; ungesunde DBs blockieren global; unmanaged
Pods/`emptyDir` stoppen am Zielnode; SUC-Controller/-Jobs sind ausgenommen,
normale Jobs werden auf Drain-Blocker geprueft; ein betroffenes fehlgeschlagenes
Backup blockiert. Der vollstaendige CI-Security-Check verlangt zudem explizite
Nonroot-Vorgaben am Controller-Pod, nicht nur dessen Container.

Die Implementierung ist mit Offline-Recovery-Tests und Manifest-Vertraegen
abgesichert (`scripts/ci/test_talos_preflight.py`, `check-talos-upgrade.sh`).
Clusterinventar, Storage-Bindung und Webhook-Ausnahme sind jetzt live geprueft.
Talos-mTLS/Erweiterungen, echte Reboot-/I/O-/Restore-Abnahme und die belegten
Worker-Blocker bleiben offen; Details im
[Runbook](../runbooks/talos-autoupdate.md). Das fruehere
[NetBird-Zugangsproblem](../runbooks/netbird-cluster-access.md) ist fuer die
Kubernetes-API behoben.
