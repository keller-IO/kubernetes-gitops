# ADR 0003 — CNPG-Storage: Node-lokal (wie Homelab) vs. Ceph RBD

- **Status:** Analyse — Entscheidung für später vorbereitet, keine Umsetzung in diesem PR
- **Datum:** 2026-07-28
- **Kontext:** Ressourcenoptimierter Talos-Cluster `keller-main`, 3 Control-Plane- + 3
  Worker-Nodes, strikt GitOps via ArgoCD

## Ausgangslage

CNPGs eigene Empfehlung ist node-lokaler Storage statt geteiltem Netzwerk-Storage —
Redundanz kommt aus der Postgres-Replikation, nicht aus der Storage-Schicht. Der User
hat im eigenen Homelab genau dieses Muster im Einsatz und wurde in der Vergangenheit vom
Gegenteil gebissen (eine DB auf geteiltem iSCSI, jahrelang unbemerkt falsch
konfiguriert). Diese Analyse prüft ergebnisoffen, ob das Homelab-Muster auch für
`keller-main` passt.

**Alle Zahlen sind markiert:** *(gemessen)* = per `kubectl get/describe/top` read-only
erhoben, *(geschätzt)* = aus gemessenen Werten hochgerechnet, *(nicht ermittelbar)* =
mit den vorhandenen Rechten/Tools read-only nicht einsehbar.

## 1. Aktueller Stand in `keller-main`

| Cluster | Namespace | Instances | Storage | StorageClass | Backup | Live? |
|---|---|---|---|---|---|---|
| `crowdsec-pg` | crowdsec | 1 | 5Gi | ceph-rbd | kein S3 (Garage-Key fehlt hier) | ✅ *(gemessen)* |
| `forgejo-pg` | forgejo | 1 | 10Gi | ceph-rbd | täglich → Garage S3, 30d | ✅ *(gemessen)* |
| `mailman-pg` | mailman | 1 | 10Gi | ceph-rbd | täglich → Garage S3, 30d | ✅ *(gemessen)* |
| `paperless-pg` | paperless-ngx | 1 | 5Gi | ceph-rbd | täglich → Garage S3, 30d | ✅ *(gemessen)* |
| `roundcube-pg` | roundcube | 1 | 5Gi | ceph-rbd | täglich → Garage S3, 30d | ✅ *(gemessen)* |
| `mastodon-pg` | mastodon | 1 | 10Gi | ceph-rbd | täglich → Garage S3, 30d | ❌ App `app-mastodon` ist `Missing` *(gemessen)* |
| `authentik-pg` | authentik | 1 | 5Gi | ceph-rbd | konfiguriert, Platzhalter (`CHANGE ME`) | ❌ aus ArgoCD-ApplicationSet ausgeschlossen (ADR 0002) *(gemessen)* |

Alle fünf laufenden Instanzen sitzen auf **`kellerio-wrk1`** — bestätigt per
`kubectl get pods -A -o wide` *(gemessen)*. Kein Cluster hat `spec.affinity`
`required` gesetzt (CNPG-Default `preferred`) — bei `instances: 1` aktuell irrelevant,
würde sich aber bei mehr Instanzen ändern müssen.

CNPG-Operator: `1.25.0` *(gemessen)*. Kein Cluster hat `spec.resources` gesetzt — die
Postgres-Container laufen ohne Requests/Limits *(gemessen, `resources: {}`)*.

## 2. Speichergrößen und Auslastung

**Deklariert (Summe der Live-PVCs):** 5 + 10 + 10 + 5 + 5 = **35Gi** *(gemessen)*.

**Tatsächlicher Verbrauch:** nicht per PVC-Belegung einsehbar (kein `df` ohne
`kubectl exec`, das war hier bewusst ausgeschlossen). CNPG-Metrics-Port (9187) und
Pod-Proxy sind per RBAC verboten (`pods/proxy` in den App-Namespaces forbidden), ebenso
der Zugriff auf VictoriaMetrics (`services/proxy` verboten trotz optimistischem
`kubectl auth can-i`-Ergebnis — das Tool ignoriert `resourceNames`-Restriktionen).
Einziger Näherungswert: die tatsächliche **RAM-Nutzung** der Postgres-Container
*(gemessen, `kubectl top pods`)*:

| Cluster | RAM aktuell |
|---|---|
| crowdsec-pg-1 | 80Mi |
| forgejo-pg-1 | 137Mi |
| mailman-pg-1 | 138Mi |
| paperless-pg-1 | 64Mi |
| roundcube-pg-1 | 73Mi |
| **Summe** | **~492Mi** |

Das sind kleine, wenig frequentierte Datenbanken — die 35Gi Storage sind mit hoher
Wahrscheinlichkeit zum Großteil ungenutzter Puffer *(geschätzt)*, aber ohne
Disk-Messung nicht belegbar.

## 3. Verfügbarer Speicherplatz — der Kern der Frage

### 3a. Ceph-Seite

Ceph läuft **extern** (Provisioner `rbd.csi.ceph.com`, `clusterID`,
Pool `kubernetes`; keine Rook-CRDs im Cluster). Von innerhalb von `keller-main` aus ist
**keine** Kapazitäts-, Nutzungs- oder Ausfall-Information erreichbar:

- Kein `ceph df`/`ceph osd pool ls detail` — das wäre nur auf dem Ceph-Cluster selbst
  möglich, nicht über Kubernetes.
- Keine Ceph-Exporter/ServiceMonitor mit Pool- oder Cluster-Kapazität im Cluster
  gefunden — nur CSI-Treiber-Metriken (`ceph-csi-rbd-*-http-metrics`, reine
  Volume-Operation-Zähler, keine Kapazität).
- `ceph-csi`-ConfigMap enthält keine Monitor-Adressen oder Pool-Größen, nur
  `auth_cluster_required`.
- Secrets im `ceph-csi`-Namespace sind per RBAC nicht lesbar (erwartungsgemäß).

**Fazit: Ceph-Gesamt-/Frei-Kapazität ist aus `keller-main` heraus nicht ermittelbar**
*(nicht ermittelbar)*. Das ist selbst ein Befund: Ceph als Backing-Storage ist für
diesen Cluster eine Black Box — man kann von hier aus nicht einmal sehen, wie knapp
oder üppig der Puffer dort ist.

### 3b. Lokale Seite (die 3 Worker)

| Node | RAM Capacity | RAM Allocatable | Ephemeral-Storage Capacity | Ephemeral-Storage Allocatable |
|---|---|---|---|---|
| kellerio-wrk1 | 8109620Ki (~7,92Gi) | 7614004Ki (~7,26Gi) | 38692Mi (~37,78Gi) | 36245916817 Bytes (~33,76Gi) |
| kellerio-wrk2 | 8109612Ki (~7,92Gi) | 7613996Ki (~7,26Gi) | 38692Mi (~37,78Gi) | 36245916817 Bytes (~33,76Gi) |
| kellerio-wrk3 | 8109616Ki (~7,92Gi) | 7614000Ki (~7,26Gi) | 38692Mi (~37,78Gi) | 36245916817 Bytes (~33,76Gi) |

*(alle gemessen, `kubectl describe node`)*

**Wichtige Einschränkung:** Das ist die Kapazität der ephemeren Partition (Container,
Logs, `emptyDir` — auf Talos i. d. R. die einzige vom Kubelet gemeldete
Storage-Metrik), **nicht** freier Platz. `nodes/proxy` (für `stats/summary`, echte
Filesystem-Auslastung) ist per RBAC verboten — die tatsächlich *freie* Kapazität ist
**nicht ermittelbar**, nur die deklarierte Gesamtkapazität. Die Worker sind
QEMU/Proxmox-VMs (`extensions.talos.dev` zeigt `qemu-guest-agent`); ob dort ein
zusätzlicher, separat gemounteter Datenträger für lokale Volumes existiert oder
angelegt werden könnte, ist über Kubernetes nicht sichtbar — das wäre nur über die
Talos-Machine-Config oder Proxmox selbst zu klären (siehe Offene Fragen).

**Die entscheidende Zahl:** 35Gi deklarierter Postgres-Storage >
**33,76Gi** allocatable Ephemeral-Storage pro Worker. Bei `podAntiAffinityType:
required` und genau 3 Workern für 3 Instanzen liegt bei jeder DB je eine Kopie auf
jedem Worker — d. h. **jeder** Worker müsste die *volle* Summe aller fünf Datenbanken
lokal vorhalten (35Gi), nicht ein Drittel davon. Das passt **nicht einmal rechnerisch**
auf einen Worker, noch bevor OS, Images, Logs oder sonstige Pods dort etwas belegen.

## 4. Referenz: wie macht es das Homelab tatsächlich

Kontext `admin@homelab-kube` (der Context `homelab-kube` existiert nicht, `homelab` ist
über NetBird nicht erreichbar aus dieser Session). 3 Nodes, **alle Control-Plane**
(kein separates Worker-Set), je ~16Gi RAM *(gemessen)*:

| Node | RAM Capacity | RAM Allocatable | Ephemeral-Storage Allocatable |
|---|---|---|---|
| talos-cp1 | 16358184Ki (~15,6Gi) | 15731496Ki (~15,0Gi) | 55573269617 Bytes (~51,76Gi) |
| talos-cp2 | 16355136Ki (~15,6Gi) | 15728448Ki (~15,0Gi) | 55573269617 Bytes (~51,76Gi) |
| talos-cp3 | 16357176Ki (~15,6Gi) | 15730488Ki (~15,0Gi) | 55573269617 Bytes (~51,76Gi) |

Also **~2× RAM und ~1,5× Ephemeral-Storage-Allocatable pro Node** gegenüber
`keller-main`-Workern *(gemessen)*.

**CNPG-Cluster im Homelab:**

| Cluster | Instances | Storage/Instanz | StorageClass | Requests/Limits (Postgres-Container) |
|---|---|---|---|---|
| `dawarich-postgres` (PostGIS) | 2 | 10Gi | `local-path` | 512Mi / 2Gi |
| `homelab-postgres` (9 Apps als *ein* geteiltes Cluster: authentik, paperless, tandoor, nextcloud, linkwarden, teslamate, goloom, forgejo, sparkyfitness) | 3 | 10Gi | `local-path` | 768Mi / 2Gi |
| `immich-postgres` (VectorChord) | 3 | 10Gi | `local-path` | 512Mi / 2Gi |

*(alle gemessen)*. Tatsächlicher RAM-Verbrauch der 8 laufenden Instanzen
*(gemessen, `kubectl top`)*: 333–489Mi je Instanz, Summe ≈ 2,6Gi.

**Was das Homelab konkret einführt, das es hier nicht gibt:**

1. **StorageClass `local-path`**, Provisioner `rancher.io/local-path`
   (Rancher local-path-provisioner) — **kein** Longhorn, **kein** TopoLVM, **kein**
   OpenEBS. Einfacher, unreplizierter hostPath-Provisioner. (Der konfigurierte Pfad
   `/var/lib/longhorn/local-path` ist ein Namens-Überbleibsel aus einer früheren
   Longhorn-Ära — Longhorn selbst läuft dort nicht mehr, nur der Pfad-Name blieb.)
2. **`VolumeBindingMode: WaitForFirstConsumer`** — dadurch entsteht das hostPath-Volume
   erst beim ersten Pod-Scheduling, mit einer `nodeAffinity.required` auf exakt den
   Node, auf dem der Pod initial landete. So bleibt die PVC dauerhaft an den Node
   gebunden, auf dem sie entstand.
3. **`affinity.podAntiAffinityType: required`** auf jedem CNPG-Cluster — zwingend nötig,
   sonst könnten zwei Replicas auf demselben Node landen und lokale Redundanz wäre
   wertlos. `keller-main` nutzt aktuell überall den CNPG-Default `preferred`.
4. **Explizite `resources.requests/limits`** pro Postgres-Container (512–768Mi /
   2Gi) — in `keller-main` ist das aktuell für keinen CNPG-Cluster gesetzt.
5. **Backup/Recovery:** identisches Muster wie hier — `barmanObjectStore` (WAL + Basis,
   30d Retention) gegen eine Garage-S3-Instanz, `target: prefer-standby` (Backup läuft
   von einer Standby-Instanz statt der Primary — nur mit `instances > 1` möglich, ein
   angenehmer Nebeneffekt echter Replikation). Für zwei der drei Cluster wird sogar per
   `bootstrap.recovery` aus dem S3-Backup wiederhergestellt statt `initdb`. **Für den
   Backup-Mechanismus selbst ändert sich durch lokalen Storage nichts** — barman/S3
   funktioniert unabhängig von der StorageClass.

## 5. Trade-offs für `keller-main` konkret

**Node-Ausfall:** Bei Ceph RBD hängt sich das Volume nach Pod-Neustart an einem
gesunden Node erneut ein — die Daten sind unabhängig vom Node-Zustand. Bei lokalem
Storage ist das Volume mit dem Node verloren, bis dieser zurückkehrt. Bei
`instances: 1` (heutiger Stand) wäre ein Wechsel auf lokalen Storage **strikt
schlechter** als heute: aktuell übersteht `instances: 1` auf Ceph einen Node-Ausfall
(Pod + Volume wandern), auf lokalem Storage nicht.

**Rebuild-Kosten bei Node-Reimage:** Das ist hier kein hypothetisches Szenario —
`kellerio-wrk3` wurde am 22.07. neu aufgesetzt, `kellerio-wrk2` fiel während des
28.07.-Incidents aus (siehe `docs/learnings/collabora-hpa-runaway.md`, Zeile 21: „durch
den gleichzeitigen Ausfall von `kellerio-wrk2`, wodurch ein Drittel der Kapazität
wegfiel"). Das sind zwei Node-Ereignisse in ca. einer Woche. Mit lokalem Storage
bedeutet jedes davon: die dort liegende Replica ist komplett weg und muss per
Basis-Backup (Netzwerk- + IO-Last, Zeit) neu aufgebaut werden — pro betroffener DB, bei
jedem Ereignis. Mit Ceph RBD betrifft ein Node-Reimage die Postgres-Daten überhaupt
nicht.

**RAM-Kosten (vermutlich der entscheidende Engpass):** Legt man das Homelab-Muster
1:1 an (konservativ 512Mi Request je Instanz) auf die 5 aktiven `keller-main`-DBs ×
3 Instanzen um, ergibt das **~7,5Gi neue Requests** *(geschätzt aus Homelab-Werten)*.
Aktuell belegte Requests über alle 3 Worker: 2428 + 4203 + 2406 = **9037Mi**, bei
insgesamt **21,8Gi** allocatable RAM über alle 3 Worker — verbleibender
Gesamt-Puffer **~13,3Gi** *(gemessen)*. Rechnerisch passt die Summe knapp, aber:

- Mit `required`-Anti-Affinity müsste **jeder** Worker 5 Instanzen (eine je DB)
  zusätzlich tragen → **~2,56Gi** neue Requests pro Worker.
- `kellerio-wrk2` hat aktuell nur **~3,23Gi** Request-Puffer übrig — das allein
  verbraucht ~79 % davon.
- Bei `limits: 2Gi` je Instanz (Homelab-Wert) wären das **10Gi Limit-Summe** durch 5
  gleichzeitige Instanzen auf einem Worker mit nur ~7,26Gi allocatable RAM — genau das
  Overcommit-Muster, das beim collabora-Incident (28.07.) schon einmal einen
  kaskadierenden Ausfall verursacht hat.

**Disk-Kosten:** 3× lokale Replikation bedeutet, dass **jeder** Worker die volle
Summe aller DBs lokal hält (siehe Abschnitt 3b: 35Gi > 33,76Gi allocatable — passt
schon rechnerisch nicht). Ceph repliziert intern vermutlich ebenfalls mit Faktor ≥2–3
(Standard-Praxis), aber auf dedizierten Storage-Hosts mit unbekannter, aber
wahrscheinlich deutlich größerer Kapazität als 33,76Gi pro Worker-VM — das lässt sich
von hier aus nicht verifizieren (siehe 3a).

**Backups:** Keine Änderung nötig — barman/S3 funktioniert identisch, unabhängig von
der StorageClass (siehe Abschnitt 4, Punkt 5).

## 6. Empfehlung

**Nicht flächendeckend, nicht jetzt.** Die beiden härtesten Zahlen sprechen dagegen:

1. Der heutige Postgres-Storage-Bedarf (35Gi) übersteigt bereits die allocatable
   Ephemeral-Storage-Kapazität eines einzelnen Workers (~33,76Gi) — bei 3 Replicas auf
   3 Workern müsste aber genau das auf jedem einzelnen Worker Platz finden.
2. Der RAM-Aufschlag für 3× Replikation über alle 5 DBs (~2,56Gi je Worker,
   konservativ gerechnet) trifft auf einen Cluster, der genau diese Art von
   Memory-Enge bereits einmal in einen Totalausfall laufen ließ (28.07.), und auf
   Worker, die durch wiederkehrende Reimages/Ausfälle (22.07., 28.07.) ohnehin
   überdurchschnittlich instabil sind — instabile Nodes sind exakt der Fall, in dem
   lokaler Storage am meisten kostet (Rebuild bei jedem Ereignis).

Das ist **kein** Widerspruch zu „Ceph ist super" — es ist unklar, wie viel Puffer Ceph
hat, weil das von hier aus nicht einsehbar ist (Abschnitt 3a). Die Empfehlung basiert
allein darauf, dass die **lokale** Seite für dieses Muster zu knapp ist, nicht darauf,
dass Ceph nachweislich reichlich Platz hätte.

**Was zutreffen müsste, damit sich das ändert:**

- Worker mit spürbar mehr RAM (Zielgröße eher Richtung Homelab: ~15Gi statt ~7,3Gi
  allocatable) und/oder ein 4. Worker, damit `required`-Anti-Affinity nicht jede DB auf
  jeden Node zwingt.
- Ein separater, für lokale PG-Volumes dedizierter Datenträger pro Worker (z. B. eine
  zusätzliche Proxmox-Disk), statt sich die ephemere Partition mit Images/Logs/anderen
  Pods zu teilen.
- Die wiederkehrenden Node-Ausfälle/Reimages sind eher die Ursache, die zuerst behoben
  gehört — lokaler Storage verschärft genau dieses Problem, statt es zu lösen.

**Günstigere Zwischenschritte, unabhängig von dieser Entscheidung:**

- `spec.resources` (Requests/Limits) für alle fünf CNPG-Cluster setzen — heute läuft
  jeder Postgres-Container ungebremst. Das ist die gleiche Lücke, die beim
  collabora-Incident zum Verhängnis wurde, nur noch nicht bei Postgres passiert. Kostet
  nichts an Architektur, schützt aber vor genau diesem Fehlerbild.
- `instances: 1 → 3` **auf Ceph RBD** wäre ein risikoärmerer erster Schritt weg vom
  Single-Point-of-Failure, ohne die Storage-Frage überhaupt anzufassen — Kosten sind
  nur RAM (siehe Rechnung oben) und zusätzliche PVCs auf Ceph (Kapazität dort unbekannt,
  siehe 3a).
- `podAntiAffinityType: preferred → required` mitziehen, sobald `instances > 1`
  irgendwo eingeführt wird — unabhängig vom Storage-Typ sinnvoll.

Falls einzelne, unkritische DBs isoliert getestet werden sollen: `roundcube-pg` oder
`paperless-pg` (je 5Gi, kleinster RAM-Fußabdruck: 73Mi/64Mi aktuell) wären die
naheliegenden Kandidaten für einen begrenzten Pilotversuch — vorausgesetzt, die
lokale Diskfrage (Abschnitt 3b) ist vorher geklärt.

## Offene Fragen / nächste Schritte

- **Ceph-Kapazität real ermitteln.** `ceph df` / `ceph osd pool ls detail` direkt auf
  dem externen Ceph-Cluster (nicht über Kubernetes erreichbar) — ohne diese Zahl bleibt
  unklar, wie viel Puffer die heutige Lösung tatsächlich hat.
- **Talos-Disk-Layout der Worker prüfen** (`talosctl disks` / Machine-Config bzw.
  Proxmox-VM-Konfiguration) — gibt es Raum für eine zusätzliche, dedizierte Disk pro
  Worker-VM für lokale PG-Volumes, statt die ephemere Partition zu belasten?
  Proxmox-Zugriff ist über `proxmox-mcp-plus` in dieser Umgebung bereits vorhanden.
- **Tatsächliche PVC-Auslastung messen** — `kubectl exec … df` (mutierend/erfordert
  Exec, hier bewusst ausgeschlossen) oder über CNPG-Metriken, sobald RBAC das für einen
  Monitoring-Zugang erlaubt (aktuell `pods/proxy` und `services/proxy` verboten).
- **Ursache der Node-Instabilität klären** (wrk2/wrk3-Ausfälle) — falls das behoben
  wird, ändert sich die Rechnung in Abschnitt 5 grundlegend.
- Falls die RAM-/Disk-Vorbedingungen irgendwann zutreffen: `local-path-provisioner`
  als neue Infrastruktur-Komponente einführen (Namespace, Deployment, StorageClass mit
  `WaitForFirstConsumer`), `podAntiAffinityType: required` setzen,
  `spec.resources` je Cluster analog Homelab-Werten definieren.
