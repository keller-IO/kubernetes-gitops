# GoPhish auf kellerIO — freigegebener Aufbau

## Ziel und Freigabe

Autorisierte Phishing-Simulation „Urlaubsplanung 2027“, vorgesehen für
07.–11.12.2026. In dieser Phase ausschließlich die interne GoPhish-Installation
als GitOps-Änderung vorbereiten. Ingo hat am 25.11.2026 den Aufbau auf kellerIO
mit einer Instanz, SQLite auf Ceph, Port-Forward-Administration, SOPS-Secrets
und zunächst ohne öffentliche Erreichbarkeit oder Mailversand bestätigt.

Keine echten Empfänger, Passwörter oder Urlaubsdaten in dieser Phase.
Ein Merge würde über ArgoCD automatisch ausrollen; deshalb PR und CI vor Merge,
keine direkten schreibenden Clusterbefehle und kein eigenmächtiger Merge.

## Ansätze

- GoPhish statt Eigenentwicklung: vom Nutzer gewählt; Kampagnenverwaltung,
  Landingpages und Auswertung müssen nicht neu entwickelt werden.
- Cluster statt eigener VM: vom Nutzer gewählt; nutzt vorhandenes ArgoCD,
  Ceph und später den bestehenden NGINX-Ingress.
- SQLite statt zusätzlicher MariaDB: freigegebene Ausnahme für eine kleine,
  einzelne Instanz. GoPhish unterstützt SQLite und MySQL, aber kein PostgreSQL.
  MariaDB wäre die sonst bevorzugte geeignete Clusteroption; sie bedeutet hier
  einen zusätzlichen Datenbankdienst ohne benötigte Mehrinstanzfähigkeit.

## Architektur und Grenzen

- Base `apps/base/gophish/`, Overlay `apps/overlays/main/gophish/`;
  vorhandenes ApplicationSet entdeckt das Overlay beim Merge automatisch.
- Namespace `gophish` mit Restricted-PodSecurity; keine Kubernetes-API-Rechte,
  kein ServiceAccount-Token, kein HPA und kein privilegierter Betrieb.
- Deployment mit einer Replik und Strategie `Recreate`.
- Separater PVC `gophish-data`: `ceph-rbd`, RWO, Filesystem,
  `Prune=false,Delete=false`, kein festes `volumeName`.
- Administrationslistener nur auf Pod-Loopback, Zugriff per
  `kubectl port-forward deployment/gophish 3333:3333 --address 127.0.0.1`.
  Phase 1 benötigt weder Admin-Service noch Ingress noch Zertifikat.
  HTTP bleibt auf Loopback und im authentifizierten Port-Forward-Tunnel.
- Landinglistener auf unprivilegiertem Port 8080; zunächst kein öffentlicher
  Service, Ingress, NodePort, LoadBalancer, hostPort oder hostNetwork.
- Default-deny für Pod-Ingress und -Egress; kein SMTP-Profil und keine
  SMTP-Freigabe. Backup-Pods erhalten getrennte Labels und eng begrenzten Egress.
- Konfiguration über ConfigMap, Datenbank unter `/data/gophish.db`.
  Direktstart der Binary statt Upstream-Wrapper, der Konfiguration überschreibt
  und ausgibt. UID, Pfade und Schreibverzeichnisse am tatsächlichen Image prüfen.
- Initialpasswort und API-Token nur SOPS-verschlüsselt. Das ursprüngliche
  Upstream-Logging des Initialpassworts ist im freigegebenen Eigenbuild
  an der Quelle entfernt und durch einen Regressionstest abgesichert.
  Nach Bootstrap Passwort wechseln; das Bootstrap-Secret ersetzt kein
  späteres Passwort.

## Backup und Datenschutz

Tägliche konsistente SQLite-Kopie per `.backup`, `PRAGMA integrity_check`,
komprimierter Upload nach eigenem Garage-Bucket `backup-gophish` mit eigenem
RW-Key ohne Owner-Rechte. Backup auf demselben Node wie der RWO-App-PVC.
Kein einfaches Kopieren der geöffneten Datenbank.

Der Implementierer legt den Job zunächst suspendiert an, falls Bucket/Key noch
nicht bereitstehen. Fehlende Backups und der externe Provisionierungsschritt
bleiben dann explizite Abnahmeblocker; keine produktiven Kampagnendaten.
Standardretention 30 Tage ist nur ein technischer Ausgangspunkt, nicht die
zugesagte Kampagnen-Löschfrist. Vor echter Nutzung Löschfrist für Live-Daten,
Backups, Snapshots, Exporte und Logs abstimmen und technisch nachweisen.
Kein Öffnungstracking oder Formular-Tracking in Phase 1.

## Vor dem Rollout zu prüfende Risiken

**Ergänzung 26.11.2026:** Das offizielle Image wurde am Sicherheitsgate
gestoppt. Ingo hat den Eigenbuild mit aktueller Go-Toolchain und geprüften
Modulupdates freigegeben. Rezept und Tests unter `images/gophish/`, Ablauf in
`docs/runbooks/gophish.md`. Die Source-Patches entfernen die Passwortausgabe
direkt und behandeln SIGTERM; ein nachgelagerter Log-Filter ist damit unnötig.
Veröffentlichung des Images und Cluster-Rollout sind noch nicht erfolgt.

Die offizielle GitHub-Release-API liefert v0.12.1 vom 14.09.2022 als neuestes
Release. Deshalb nicht blind deployen: verfügbares Image, Digest, Architektur,
Abhängigkeiten und Start unter Restricted-Security lokal prüfen. Ein erhebliches
ungelöstes Sicherheitsproblem blockiert den Rollout und wird Ingo vorgelegt.

PVC-Größe und Ressourcenwerte sind Entscheidungen des Implementierers:
zunächst 1 GiB, CPU 100m/500m, RAM 128Mi/512Mi als zu prüfende Startwerte;
nach lokalem Test und späterer read-only Messung anpassen.

## Spätere, separat freizugebende Phase

Domainregistrierung, DNS, Zertifikate, öffentlicher Landingpage-Ingress,
SMTP-Identität samt SPF/DKIM/DMARC, Testmail und Kampagnenstart. Vor echtem
Versand Auftrag, Empfängerkreis, Zugriffsrechte und Datenschutz klären.
Scannerabrufe sind kein Beweis menschlicher Klicks; die Auswertung muss das
ausweisen. Keine Zugangsdaten sammeln.

## Quellen

- https://docs.getgophish.com/user-guide/installation
- https://github.com/gophish/gophish/releases/tag/v0.12.1
- Upstream `v0.12.1/models/models.go` (Bootstrap und Datenbanktreiber),
  `docker/run.sh` (Konfigurationsausgabe).
- `docs/runbooks/backup-restore.md` (Garage/SQLite)
- `docs/learnings/argocd-prune-pvc-bei-quellenwechsel.md`
