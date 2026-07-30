# CephFS nach einem langen Node-Stall explizit auf I/O testen

## Kontext

Der ausloesende Incident trat am 29./30.07.2026 auf `u22` auf, nicht auf einem
Kubernetes-Node: Der Linux-Host hing rund eine Stunde im Kernel und verlor
waehrenddessen seine Sessions zum externen CephFS. Nach der Rueckkehr waren die
Kernel-Mounts weiterhin in der Mount-Tabelle eingetragen, jeder Zugriff endete
aber mit `Permission denied`. Auf der MDS-Seite existierte keine gueltige Session
des Clients mehr.

Der kellerIO-Cluster nutzt derzeit nur den RBD-Treiber von ceph-csi. Der
CephFS-CSI-Treiber und die dafuer notwendigen MDS-Caps fehlen noch. Dieses
Learning beschreibt deshalb eine Abnahmebedingung fuer die zukuenftige
CephFS-/RWX-Nutzung und keinen bereits beobachteten Kubernetes-Ausfall.

## Symptom

Nach einem langen Node-Stall koennen gleichzeitig folgende Aussagen wahr sein:

- Der Node ist wieder erreichbar oder in Kubernetes `Ready`.
- Der Kernel fuehrt den CephFS-Mount weiterhin als gemountet.
- Pods koennen wieder `Running` sein.
- Der Ceph-MDS hat die alte Client-Session trotzdem verworfen oder blocklisted.
- Reale Dateioperationen auf dem CephFS schlagen fehl oder haengen.

Ein wiederhergestellter Node- oder Podstatus beweist daher nicht, dass ein
CephFS-Volume wieder nutzbar ist.

## Ursache

Der CephFS-Kernel-Client muss seine MDS-Session und Caps regelmaessig erneuern.
Wenn der gesamte Node laenger als das Session-Timeout stillsteht, kann der MDS
den Client evicten beziehungsweise blocklisten. Der alte Kernel-Mount kann
danach sichtbar bleiben, obwohl er keine gueltige Session mehr besitzt.

Im Quellincident kamen ein MDS-Wechsel und Meldungen wie `session blocklisted`,
`reconnect denied` und `null i_snap_realm` hinzu. Die kontrollierte Neuerzeugung
der Mounts stellte neue, offene MDS-Sessions her.

Das ist nicht mit einem gewoehnlichen Pod-Crash gleichzusetzen. Bei CephFS-CSI
liegt der Kernel-Mount auf dem Kubernetes-Node; ein Containerneustart allein
muss den nodeweiten Mount deshalb nicht ersetzen.

## Uebertragung auf Talos und CSI

Talos wird nicht wie ein klassischer Debian-Host ueber SSH, systemd oder
manuelle `/etc/fstab`-Mounts repariert. Diagnose und Recovery muessen die
Talos- und CSI-Lebenszyklen respektieren:

1. Nodezustand, betroffene Pods, PVCs und Events erfassen.
2. Kernelmeldungen ueber `talosctl dmesg` und CSI-Node-Plugin-Logs ueber
   `kubectl logs` pruefen.
3. Auf der externen Ceph-Seite MDS-Zustand, Blocklist und Client-Sessions
   kontrollieren.
4. Einen echten Lese-/Schreibtest auf dem PVC ausfuehren. Bei RWX muss der Test
   von Pods auf mindestens zwei verschiedenen Nodes erfolgen.
5. Recovery zuerst ueber Pod-Neuerstellung und CSI `NodeUnpublish`/`NodePublish`
   versuchen. Bleibt die nodeweite Session stale, Workloads kontrolliert
   drainen und den betroffenen Talos-Node neu starten.
6. Erst nach erfolgreichem I/O-Test und sichtbarer neuer MDS-Session gilt die
   Stoerung als behoben.

Manuelles `mount`/`umount` im Talos-Hostnamespace ist kein dauerhaftes
GitOps-Verfahren. Ebenso darf eine Ceph-Blocklist nicht blind geleert werden,
ohne den betroffenen Client und eine eventuell noch aktive Session zu klaeren.

## Diagnose

Read-only Vorpruefung:

```sh
kubectl get nodes -o wide
kubectl get pods --all-namespaces -o wide
kubectl get pvc,pv --all-namespaces
kubectl get events --all-namespaces --sort-by=.lastTimestamp
talosctl -n <node-ip> dmesg | grep -E 'ceph|libceph|blocklist|reconnect|i_snap_realm'
```

Sobald CephFS-CSI deployt ist, zusaetzlich die Logs des Node-Plugins auf dem
betroffenen Node pruefen:

```sh
kubectl -n ceph-csi logs <cephfs-node-pod> -c csi-cephfsplugin --since=30m
```

Der funktionale Test gehoert in einen freigegebenen Test-Namespace und muss
Dateierzeugung, `fsync`, erneutes Lesen und einen Cross-Node-Leser umfassen. Nur
`kubectl get pvc` oder `stat` auf dem Mountpoint reicht nicht.

## Abgrenzung zum u22-Incident

Nicht in dieses Kubernetes-Projekt uebertragbar sind:

- der konkrete i915-OOM-Notifier-Logsturm und dessen Modul-Blacklist,
- journald-Watchdog und verlorene journald-Meldungen,
- direkte systemd-Remount-Kommandos fuer die u22-Backupmounts,
- PBS-Proxy-Dateideskriptoren und systemd-`LimitNOFILE`.

i915 ist fuer Talos nur relevant, wenn ein Cluster-Node vergleichbare Intel-GPU-
Hardware aktiv nutzt. Talos-Kerneldiagnose erfolgt ueber `talosctl` und zentrale
Metriken, nicht ueber nachinstallierte Hostpakete. Insbesondere misst ein lokal
ausgefuehrtes `iostat` nicht die I/O-Wartezeiten eines entfernten Talos-Nodes.

## Konsequenz

- CephFS-CSI erst aktivieren, wenn Cross-Node-RWX und Recovery nach einem
  kontrollierten Node-Reboot erfolgreich getestet sind.
- Nach Node-Stalls nicht nur Kubernetes-Objektstatus, sondern immer reales
  Volume-I/O und die MDS-Client-Session pruefen.
- Alerts fuer CSI-Mountfehler, CephFS-Sessionprobleme und blockierte Pods
  einrichten, bevor produktive RWX-Workloads auf CephFS umgestellt werden.
- Backup-Ueberwachung muss den Zeitpunkt des letzten erfolgreichen Backups und
  aufeinanderfolgende Fehler pruefen. Ein vorhandener Zeitplan ist kein
  Erfolgsnachweis.
- Das Learning gilt fuer den zukuenftigen CephFS-Kernel-CSI-Pfad. Es ist kein
  Beleg fuer dasselbe Fehlerbild beim aktuell aktiven RBD-CSI-Treiber.
