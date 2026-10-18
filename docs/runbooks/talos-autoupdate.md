# Talos-Updates fuer keller-main

## Stand und Freigabe

Stand 18.10.2026: Die GitOps-Implementierung liegt unter
`infrastructure/base/system-upgrade-controller/`. Das Infrastruktur-ApplicationSet
findet sie automatisch. **Der Rollout ist noch nicht freigegeben:** kein Node
bekommt durch diese Aenderung das Opt-in-Label `keller.io/talos-upgrade=enabled`.
Dieses Label gehoert nach Abnahme in die deklarative Talos-Node-Konfiguration im
Repository `keller-IO/infrastructure`, nicht in einen manuellen Patch.

Der IaC-Stand nennt drei Control-Planes (2 GiB) und drei Worker (8 GiB), Talos
`v1.13.4`, Plattform `nocloud`, Schematic
`3abf06e1d81e509d779dc256f9feae6cd6d82c69337c661cbfc383a92594faf5`.
Diese Angaben sind **kein Live-Inventar**. Das initiale Plan-Ziel entspricht
diesem Stand. Renovate aktualisiert Patch-Versionen innerhalb 1.13 nach sieben
Tagen und erfolgreicher CI. Minor-/Major-Wechsel brauchen Review und eine
Anpassung der erlaubten Versionslinie; keine Minor-Version ueberspringen.
Talos-OS-Updates aktualisieren Kubernetes nicht.

Am 18.10.2026 hatte `main` weder Branch Protection noch aktive Rulesets.
Fuer Talos-Patches gilt deshalb `platformAutomerge: false`, `ignoreTests: false`:
Renovate prueft die Checks selbst vor dem Merge. Eine separate Absicherung von
`main` durch verpflichtende CI-Checks bleibt empfohlen; diese Aenderung schreibt
keine Repository-Einstellungen um. Siehe
[Renovate platformAutomerge](https://docs.renovatebot.com/configuration-options/#platformautomerge).

Das Homelab nutzt seit 15.10.2026 Omni. keller-main ist laut vorhandener IaC
weiter OpenTofu/Talos-verwaltet. Deshalb wird hier der vorherige SUC-Ablauf mit
seinen korrigierten Drain-Regeln uebernommen. Eine Omni-Migration waere ein
eigener Wechsel der Konfigurationshoheit. SUC und Omni duerfen nicht parallel
denselben Cluster aktualisieren.

## Vor der Aktivierung

1. Read-only-Zugang gemaess [NetBird-Zugang](netbird-cluster-access.md) herstellen;
   den tatsaechlichen Talos-/Kubernetes-Stand, Node-Rollen, Ressourcen und
   Webhooks erfassen. Die Drain-kubectl-Version muss innerhalb der offiziellen
   Versionsabweichung von einer Minor-Version zur API liegen.
2. Die aktiven CNPG-Cluster muessen mindestens drei gesunde Instanzen,
   `affinity.podAntiAffinityType: required` und aktivierte PDBs haben. Es braucht
   zwei moegliche Standbys, damit der Neustart einer Replica den naechsten
   Switchover nicht blockiert. `failoverDelay: 30` nach Abgleich mit den
   Verfuegbarkeitsanforderungen setzen. Der aktuelle Git-Stand enthaelt zehn
   Singletons (einschliesslich des ausgeschlossenen Authentik-Bestands);
   Live-Zustand und aktive Cluster bleiben zu pruefen.
3. Vor zusaetzlichen Datenbankreplicas **N-1-Kapazitaet und Ceph-Kapazitaet** aus
   aktuellen Requests und Messwerten nachweisen. Die Implementierung skaliert
   Datenbanken nicht blind hoch und deaktiviert keine PDBs. Replikationsaufbau
   und kontrolliertes Rebalancing zuerst abschliessen; erst danach Nodes
   freigeben. Ceph-RBD bleibt bestehen. Die Homelab-Migration von Datenbanken auf
   lokale Disks wird nicht mit einem OS-Update vermischt.
4. RWO-Anwendungen pruefen: `Recreate` oder eine vom Chart garantierte
   Single-Writer-Strategie, funktionierende Readiness-/Startup-Probes,
   ausreichende `terminationGracePeriodSeconds` und bei Bedarf `preStop`.
   PDB, harte Affinitaet, lokale PVs, unmanaged Pods und nicht ersetzbares
   `emptyDir` koennen einen Drain absichtlich blockieren. Daten erst bewerten,
   nicht `force` oder `deleteEmptydirData` pauschal einschalten.
5. Backup-Erfolg und Wiederherstellbarkeit von Datenbanken/PVCs sowie einen
   aktuellen etcd-Recovery-Punkt bestaetigen. Ceph/CSI-Gesundheit pruefen;
   `Running`, `Ready` und ein gebundenes PVC beweisen kein funktionierendes I/O.
   Siehe [CephFS-Learning](../learnings/external-cephfs-client-stall-recovery.md).
6. Ein dediziertes, zeitlich gueltiges Talos-mTLS-Credential ausserhalb von Git
   provisionieren: Namespace `system-upgrade-controller`, Secret `talosconfig`,
   Key `talosconfig`. Das bestehende OpenTofu-Modul stellt die Konfiguration
   bereit; die Secret-Provisionierung muss dort als separater, reviewed Schritt
   ergaenzt werden. Kein Admin-Kubeconfig fuer Agenten verwenden. CA, Client-Rolle
   fuer OS-Upgrades und die Erreichbarkeit jedes Node-TCP-Endpunkts verifizieren.
   Vor Freigabe mit exakt diesem Credential fuer jeden Node pruefen:

   ```sh
   talosctl --talosconfig <dediziertes-credential> -e <node-ip> -n <node-ip> version
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
8. Zuerst einen Worker als Canary in IaC freigeben. Reboot, neue OS-Version,
   Scheduling, DB-Readiness, Services und echtes Volume-I/O abnehmen. Danach die
   restlichen Nodes deklarativ freigeben. Keine automatische Aktivierung allein
   aufgrund eines gruenen Manifest-Tests.

## Ablauf und Grenzen

Es gibt einen Plan fuer alle freigegebenen Linux-Nodes, `concurrency: 1`, ohne
`exclusive`. Controller und Upgrade-Jobs haben unterschiedliche Labels; die
Controller-Anti-Affinitaet selektiert nur Controller. Der Controller darf beim
Reboot seines eigenen Nodes auf eine andere Control-Plane wechseln.

Vor **jedem** Drain liest das Python-Prepare ausschliesslich Kubernetes-Status:
alle Nodes Ready und schedulable, CNPG vollstaendig gesund und verteilt,
Deployment-/StatefulSet-/DaemonSet-Replicas und laufende Nicht-Job-Pods bereit,
kein fail-closed Pod-Webhook fuer `kube-system`. Bereits durch diesen Plan als
bearbeitet markierte Nodes muessen die Ziel-OS-Version melden. Diese Bedingungen
muessen 60 Sekunden durchgehend erfuellt sein. API-/RBAC-/TLS-Fehler setzen die
Wartezeit zurueck; nach 15 Minuten bricht Prepare vor dem Cordoning ab.
Kurzlebige Jobs werden nicht pauschal als unbereite Workloads gewertet.

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

Mit dem gesondert geprueften Read-only-Kontext:

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
