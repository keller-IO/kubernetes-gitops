# Talos-Updates fuer keller-main

## Stand und Freigabe

Stand 18.10.2026: Die GitOps-Implementierung liegt unter
`infrastructure/base/system-upgrade-controller/`. Das Infrastruktur-ApplicationSet
findet sie automatisch. **Der Rollout ist noch nicht freigegeben:** kein Node
bekommt durch diese Aenderung das Opt-in-Label `keller.io/talos-upgrade=enabled`.
Dieses Label gehoert nach Abnahme in die deklarative Talos-Node-Konfiguration im
Repository `keller-IO/infrastructure`, nicht in einen manuellen Patch.

Die Live-Pruefung am 18.10.2026 bestaetigt acht Ready-Nodes (drei Control-Planes,
fuenf Worker), Talos **v1.13.4** und Kubernetes **v1.36.0**. Der aktuelle
IaC-Ref `keller/main` (`685f5d9`) beschreibt dieselben acht Nodes mit 6-GiB-CPs
und 8-/12-GiB-Workern. Seit dem Nachmittag des 18.10. laufen wrk1 bis wrk3 und
wrk5 mit 12 GB, wrk4 mit 8 GB (keller-IO/infrastructure#17 gleicht die tfvars an). Der lokale IaC-Branch `main` liegt dagegen 31 Commits
zurueck und enthaelt eine andere Schematic; Abgleiche erfolgen gegen den
aktuellen Remote-Ref. Kapazitaet, laufende Wartung und belegte Blocker stehen
in der [Live-Abnahme](talos-live-audit-2026-10-18.md).
Das initiale Plan-Ziel bleibt v1.13.4. Die Bootstrap-Schematic ist
`3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5`, Plattform
`nocloud`; deren tatsaechliche Erweiterungen muessen noch per Talos geprueft werden.
Renovate aktualisiert Patch-Versionen innerhalb 1.13 nach sieben Tagen und
erfolgreicher CI. Minor-/Major-Wechsel brauchen Review und eine Anpassung der
erlaubten Versionslinie; keine Minor-Version ueberspringen.
Talos-OS-Updates aktualisieren Kubernetes nicht.

Das aktive Ruleset `main_protection` erzwingt inzwischen den erfolgreichen Check
`ci-required` und einen aktuellen PR-Stand. Fuer Talos-Patches bleiben
`platformAutomerge: false`, `ignoreTests: false` gesetzt. CI- und Integrations-
Vertrag: [ci-safety.md](ci-safety.md).

Das Homelab nutzt seit 15.10.2026 Omni. keller-main ist laut vorhandener IaC
weiter OpenTofu/Talos-verwaltet. Deshalb wird hier der vorherige SUC-Ablauf mit
seinen korrigierten Drain-Regeln uebernommen. Eine Omni-Migration waere ein
eigener Wechsel der Konfigurationshoheit. SUC und Omni duerfen nicht parallel
denselben Cluster aktualisieren.

## Vor der Aktivierung

1. Die [Live-Abnahme](talos-live-audit-2026-10-18.md) vor dem Freigabetermin
   aktualisieren. Der Kubernetes-Zugang funktioniert; ein zusaetzlicher
   Agent-Zugang ist keine technische Voraussetzung. Stand 18.10.2026 abends ist
   kein Node mehr cordoned: Der Cordon auf `kellerio-wrk4` (06:18 UTC, Wartung
   aus einer Agent-Sitzung) ist aufgehoben, seine Systemplatte liegt seit 17:19
   auf cloud62 `local-zfs` statt Ceph. Vor jeder Freigabe trotzdem pruefen, dass
   keine andere Wartung laeuft, und keinen zweiten Node parallel in Wartung nehmen. Der Drain-Client ist auf die beobachtete
   Kubernetes-Version 1.36.0 angepasst.
2. Nur CNPG-Cluster mit einer Instanz auf dem **zu drainenden Node** brauchen
   mindestens drei gesunde Instanzen, `affinity.podAntiAffinityType: required`,
   aktivierte Anti-Affinity und PDBs. Es braucht zwei moegliche Standbys, damit
   der Neustart einer Replica den naechsten Switchover nicht blockiert.
   `failoverDelay: 30` mit den Verfuegbarkeitsanforderungen abgleichen. Global
   muessen weiterhin alle CNPG-Replicas gesund und Switchovers abgeschlossen
   sein. Neun Singletons sind live, der zehnte Authentik-CR ist nur Altbestand.
   Keine DB-Instanz laeuft auf Control-Planes; deren Update verlangt deshalb
   keine pauschale Worker-DB-Skalierung. Fuenf MariaDB-Singletons bleiben ein
   separates Unterbrechungsrisiko fuer Worker-Updates.
3. Vor zusaetzlichen Datenbankreplicas **N-1-Kapazitaet und Ceph-Kapazitaet**
   nachweisen. HA3 fuer alle neun CNPG-Cluster braucht zusaetzlich 6656 MiB
   RAM-Requests, 2600m CPU und 268 GiB logischen PVC-Speicher. Seit der
   RAM-Erweiterung vom 18.10. besteht die N-1-Rechnung mit 20 % Reserve
   rechnerisch (nach Ausfall des groessten Workers ca. 15800m / 41802 MiB gegen
   benoetigte 14444m / 40592 MiB, ca. 1,2 GiB Spielraum, siehe #286). Zwei
   weitere Worker sind daraus nicht mehr abzuleiten. Harte Platzierungsregeln,
   Reserve anderer Workloads und Ceph-Freikapazitaet sind damit noch **nicht**
   nachgewiesen. Die Zahlen der [Live-Abnahme](talos-live-audit-2026-10-18.md)
   sind eine historische Momentaufnahme. Keine blinde Erhoehung, keine PDB-Abschaltung,
   keine Request-Reduktion aus einer einzelnen Nutzungsprobe. Replikationsaufbau
   und Rebalancing vor Node-Freigabe abschliessen. Ceph-RBD bleibt bestehen;
   die Homelab-Migration auf lokale Disks wird nicht mit dem OS-Update vermischt.
4. RWO-Anwendungen pruefen: `Recreate` oder eine vom Chart garantierte
   Single-Writer-Strategie, funktionierende Readiness-/Startup-Probes,
   ausreichende `terminationGracePeriodSeconds` und bei Bedarf `preStop`.
   PDB, harte Affinitaet, lokale PVs, unmanaged Pods und nicht ersetzbares
   `emptyDir` koennen einen Drain absichtlich blockieren. Daten erst bewerten,
   nicht `force` oder `deleteEmptydirData` pauschal einschalten.
5. Backup-Erfolg und Wiederherstellbarkeit von Datenbanken/PVCs sowie einen
   aktuellen etcd-Recovery-Punkt bestaetigen. Mailman und Mastodon haben aktuell
   fehlgeschlagene Backup-CRs sowie `LastBackupSucceeded=False`; einen neueren
   `lastSuccessfulBackup`-Zeitstempel nicht allein als Erfolg werten. Neue
   completed Backups und Restore-Nachweis verlangen. Ceph/CSI-Gesundheit pruefen;
   `Running`, `Ready` und ein gebundenes PVC beweisen kein funktionierendes I/O.
   Siehe [CephFS-Learning](../learnings/external-cephfs-client-stall-recovery.md).
6. Das Talos-mTLS-Credential stellt **Talos selbst** aus (#287):
   - OpenTofu (`keller-IO/infrastructure`, Env `kellerIO`,
     `extra_controlplane_config_patches`) aktiviert auf den Control Planes
     `machine.features.kubernetesTalosAPIAccess` mit `allowedRoles: [os:admin]`
     und `allowedKubernetesNamespaces: [system-upgrade-controller]`.
   - GitOps legt die CR `talos.dev/v1alpha1 ServiceAccount` `talosconfig`
     (`talos-serviceaccount.yaml`) mit `roles: [os:admin]` an.
   - Talos erzeugt daraus Secret `talosconfig`, Key **`config`**:
     Client-Zertifikat der OS-CA, **6 h gueltig, 1 h vor Ablauf automatisch
     erneuert**. Kein Zertifikat in Git, im Tofu-State oder als Handarbeit; eine
     Rotation braucht keinen Eingriff.
   - **Rolle:** `os:admin` ist zwingend. In Talos 1.13 verlangt
     `MachineService/Upgrade` genau diese Rolle, `os:operator` reicht nicht.
     Begrenzt wird ueber den Namespace und darueber, dass nur die Jobs des Plans
     `talos` das Secret mounten.
   - **Reihenfolge:** erst das Tofu-Feature ausrollen (die CRD
     `serviceaccounts.talos.dev` existiert erst danach), dann die GitOps-CR
     syncen.
   - Vor Freigabe mit exakt diesem Credential, aus einem HostNetwork-Pfad wie
     dem Job, fuer jeden Node pruefen:

   ```sh
   talosctl --talosconfig /var/run/secrets/talos.dev/config -e <node-ip> -n <node-ip> version
   ```

   Der Prepare-Check erkennt ein fehlendes oder leeres Credential. Er ersetzt
   **keinen mTLS-/Rollen-Test**; der Kubernetes-SA hat keine Leserechte auf Secrets.
   Rotation des Credentials loest dank `ignoreUpdates: true` keinen neuen
   OS-Rollout aus. Das Secret ist optional gemountet, damit der Check bei Fehlen
   vor dem Drain verstaendlich abbricht.
7. Installationsimage und Systemerweiterungen mit IaC abgleichen. Ein generisches
   `ghcr.io/siderolabs/installer` wuerde die eigene Schematic verlieren.
   `talosctl upgrade` schreibt `machine.install.image` nicht zurueck; GitOps
   ist der Upgrade-Owner, OpenTofu weiter Provisionierungs-/Config-Owner.
   Vor spaeteren `tofu apply` die Bootstrap-Version nachziehen und den Plan auf
   konkurrierende OS-/Kubernetes-Aenderungen pruefen.
8. Nach Abschluss der bestehenden Wartung und Talos-Abnahme zunaechst cp1 oder
   cp3 als Canary in IaC freigeben. Dort wurden keine normalen Drain-Kandidaten
   beobachtet. cp2 hat einen SMB-Controller mit blockierendem Socket-`emptyDir`.
   Worker erst nach der getrennten DB-/Kapazitaets-/Storage-Abnahme aktivieren.
   Reboot, neue OS-Version,
   Scheduling, DB-Readiness, Services und echtes Volume-I/O abnehmen. Danach die
   restlichen Nodes deklarativ freigeben. Keine automatische Aktivierung allein
   aufgrund eines gruenen Manifest-Tests.

## Ablauf und Grenzen

Es gibt einen Plan fuer alle freigegebenen Linux-Nodes, `concurrency: 1`, ohne
`exclusive`. Controller und Upgrade-Jobs haben unterschiedliche Labels; die
Controller-Anti-Affinitaet selektiert nur Controller. Der Controller darf beim
Reboot seines eigenen Nodes auf eine andere Control-Plane wechseln.

Vor **jedem** Drain liest das Python-Prepare ausschliesslich Kubernetes-Status:
alle Nodes Ready und schedulable, alle CNPG-Replicas gesund und Switchovers
abgeschlossen; betroffene Datenbanken brauchen HA und reale Node-Streuung,
Deployment-/StatefulSet-/DaemonSet-Replicas und laufende Nicht-Job-Pods bereit,
kein fail-closed Pod-Webhook fuer `kube-system`. Bereits durch diesen Plan als
bearbeitet markierte Nodes muessen die Ziel-OS-Version melden. Diese Bedingungen
muessen 60 Sekunden durchgehend erfuellt sein. API-/RBAC-/TLS-Fehler setzen die
Wartezeit zurueck; nach 15 Minuten bricht Prepare vor dem Cordoning ab.
Jobs werden nicht pauschal als unbereite Workloads gewertet; normale aktive
Jobs auf dem Zielnode werden aber wie andere Drain-Kandidaten auf `emptyDir`
geprueft. Mirrors und DaemonSets sind ausgenommen. SUC-Pods mit Label
`upgrade.cattle.io/controller` folgen derselben Ausnahme wie im nativen Drain.
Unmanaged Pods und nicht freigegebene `emptyDir`-Volumes stoppen vor dem
Cordoning. Das verhindert einen vermeidbaren Drain-Fehler mit cordoned Node.
Ein explizit fehlgeschlagenes letztes Backup einer betroffenen DB blockiert auch.

Dann evictet SUC unter Beachtung der PDBs und der Pod-Grace-Periods, bis zu
20 Minuten. Kein Force-Delete, kein Eviction-Bypass, kein pauschales Loeschen
von `emptyDir`. Erst nach erfolgreichem Drain ruft der Job die laufende Talos-API
mit mTLS und expliziten TCP-Parametern `-e` und `-n` auf. `--insecure` ist fuer
Maintenance-Mode und passt hier nicht. SUC drainiert; deshalb bekommt Talos
`--drain=false`. Die Job-Gesamtfrist betraegt 90 Minuten.

`--wait=false` bestaetigt nur die Annahme des Talos-Auftrags. Der Job laeuft auf
dem neu zu startenden Node und kann seinen eigenen Reboot nicht zuverlaessig
ueberwachen. SUC-Job/Plan `Complete` ist deshalb **kein Nachweis fuer erfolgreiche
OS- und Workload-Recovery**. Nach dem Job folgen mindestens fuenf Minuten Pause
und vor dem naechsten Node erneut die Zustandspruefung. Ein Rollback oder ein
haengender Reboot blockiert so den naechsten Drain. Beim **letzten** Node gibt es
keinen nachfolgenden Prepare-Check: dessen OS-Version, Gesundheit und I/O muessen
als Postflight separat kontrolliert werden. Die Loesung garantiert keine
unterbrechungsfreien Singletons und ersetzt keine laufende Ueberwachung.

SUC erzeugt Jobs mit HostNetwork/HostPID/HostIPC und einem Host-Root-Volume.
Diese Upstream-Vorgabe laesst sich in dieser Version nicht per Plan abschalten.
Deshalb braucht nur dieser Namespace die privilegierte PodSecurity-Ausnahme;
die Talos-/Prepare-Container selbst laufen ohne Privileged-Modus. Der
Job-ServiceAccount bekommt nur Node-Cordon/Labels, Evictions und Statusleserechte,
keine pauschalen Pod-Deletes oder Secret-Leserechte.

## Beobachten und bei Fehlern stoppen

Mit dem expliziten Kubernetes-Kontext:

```sh
kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main get nodes -o wide
kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main -n system-upgrade-controller get plans,jobs,pods
kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main get clusters.postgresql.cnpg.io,pdb -A
kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main get pods -A -o wide
```

Bei haengendem Prepare oder Drain zuerst dessen Logs und PDBs lesen. Ein
unfertiger Lauf darf keine weiteren Nodes drainieren. Fuer einen geplanten Halt
Opt-in aus IaC entfernen; ein bereits gestarteter Job laeuft dadurch weiter.
Bei einem Incident muss ein Mensch mit benannter Schreibfreigabe den Controller
pausieren **und laufende Jobs gesondert pruefen/stoppen**. ArgoCD-Auto-Sync kann
manuelle Replica-Aenderungen zuruecksetzen: die betreffende Application fuer die
Incident-Dauer kontrolliert pausieren oder die Pause ueber Git vorgeben.

Einen cordoned Node erst wieder freigeben, nachdem geklaert ist, ob ein
Talos-Upgrade noch laeuft. Vor CNPG-Replica-Reparatur den Updater anhalten und
den gesunden Node kontrolliert uncordonen: CNPG kann bei einem Primary auf
unschedulable Nodes weitere Reconciliation auf einen Switchover vertagen.
Nie PDBs oder PVCs pauschal loeschen, nur um ein Update zu erzwingen.

Bei `FailedCreate ... webhook` zuerst Admission reparieren. Nach Behebung kann
DaemonSet-Backoff bis zu 15 Minuten nachlaufen. Bei 502 zuerst Endpoints und
Backend-Readiness pruefen; bei RWO-Multi-Attach die Single-Writer-Strategie und
CSI-Detach/Attach. Ein automatischer OS-Rollback ist keine Datenbank-Recovery.

## Quellen

- [Talos: Upgrade-Sequenz und unterstuetzte Versionspfade](https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
- [SUC Plan-API](https://github.com/rancher/system-upgrade-controller/blob/v0.20.2/pkg/apis/upgrade.cattle.io/v1/types.go)
- [Kubernetes: sicherer Node-Drain](https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/)
- [Kubernetes: Version Skew](https://kubernetes.io/releases/version-skew-policy/)
- [Uebertragene Homelab-Learnings](../learnings/talos-upgrade-drain-safety.md)
