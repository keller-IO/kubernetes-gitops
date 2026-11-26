# GoPhish intern auf kellerIO — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine überprüfte, intern abgeschottete GoPhish-Installation als PR vorbereiten, ohne öffentlichen Zugriff oder Mailversand.

**Architecture:** Eine GoPhish-Replik mit SQLite auf separatem Ceph-RBD-PVC, Administration ausschließlich über Loopback-Port-Forward. Kustomize-Base und Overlay werden nach Review und Merge automatisch von ArgoCD erkannt; Backups nutzen konsistente SQLite-Kopien und app-eigene Garage-Zugangsdaten.

**Tech Stack:** Kubernetes/Talos, ArgoCD, Kustomize, GoPhish, Ceph-RBD, SQLite, SOPS/age, Garage S3.

**Spec:** `docs/superpowers/specs/2026-11-25-gophish-internal-design.md`

## Global Constraints

- Namespace `gophish`, eine Replik, Strategie `Recreate`, kein HPA.
- SQLite ist eine ausdrücklich dokumentierte Ausnahme von der Datenbankreihenfolge.
- Keine öffentlichen Endpoints, DNS-/Domain-/Zertifikatsänderungen oder SMTP-Freigabe.
- Keine echten Empfänger, Passwörter oder Urlaubsdaten in dieser Phase.
- Keine schreibenden Clusterbefehle, kein eigenmächtiger Merge.
- Keine Klartext-Secrets in Git, Terminalausgabe oder Testprotokollen.
- PVC `gophish-data`: `ceph-rbd`, RWO, Filesystem,
  `Prune=false,Delete=false`, kein festes `volumeName`.
- Administrationslistener nur auf Pod-Loopback; lokales Port-Forward-Binding 127.0.0.1.
- Upstream-Alter und Image-Prüfung sind Rollout-Gates, keine still akzeptierten Risiken.

## Review Focus

1. Neustart/Upgrade: Daten und geändertes Adminpasswort bleiben erhalten; nur ein DB-Schreiber.
2. Fremder Pod: kein Zugriff auf Admin/Landingpage; SMTP und beliebiges Internet bleiben gesperrt.
3. Bootstrap: Passwort darf nicht als Log-Ausgabe an zentrale Leser gelangen.
4. Backup während DB-Schreibzugriff: konsistenter Snapshot, Integritätsfehler verhindern Upload.
5. Restore/Löschung: Backups enthalten personenbezogene Daten; kein voreiliges Löschversprechen.

---

## Dateistruktur

- `apps/base/gophish/{kustomization,namespace,workload,pvc,network-policy}.yaml`:
  lokale Ressourcen, keine unbenötigten Datenbank-/Cache-CRs.
- `apps/base/gophish/config.json`: Konfiguration ohne Geheimnisse.
- `apps/base/gophish/{secret-generator.yaml,secret.sops.yaml}`: KSOPS-Bootstrap.
- `apps/base/gophish/backup.yaml`: SQLite-Snapshot und S3-Upload.
- `apps/base/gophish/backup-s3.sops.yaml`: nur bei echten app-eigenen Credentials.
- `apps/base/gophish/test_contract.py`: statischer Kontrakt für gerenderte Ressourcen.
- `apps/overlays/main/gophish/kustomization.yaml`: Referenz auf Base.
- `scripts/ops/test-gophish-contract.sh`: isolierter lokaler Image-/Persistenztest.
- `justfile`: Tests in vorhandene Rezepte aufnehmen.
- `docs/runbooks/gophish.md`: Zugriff, Bootstrap, Backup/Restore, spätere Freigaben.
- `docs/PRODUCTION-READINESS.md`: tatsächlicher Stand und Abnahmeblocker.

### Task 1: Image und internes Deployment

**Freigegebene Anpassung 26.11.2026:** Nach dem Sicherheitsstopp eigener
Build statt altem Upstream-Image. `images/gophish/` hält Source-Commit,
Modul-Lockfiles, Source-Patch und Runtime-/Scan-Tests;
`scripts/ops/build-gophish-image.sh` und `just gophish-build` bauen lokal.
Bootstrap-Passwortausgabe direkt an der Quelle entfernen statt Shell-Logfilter.
Ersten Registry-Push vor Veröffentlichung gesondert freigeben lassen.
Bis dahin Task 1 nur teilweise bearbeitet, keine Deployment-Fertigmeldung.

**Interfaces:** Konsumiert offizielles GoPhish-Image und SQLite-Konfiguration.
Produziert ein lokal startfähiges, exakt per Digest gepinntes Deployment
`gophish`, PVC `gophish-data` und Overlay ohne externe Freigaben.

- [ ] Image-Tag für v0.12.1 und Digest/Plattform über Registry verifizieren;
  tatsächliche UID/GID, Binary-, Static- und Migrationspfade prüfen.
  Sicherheitsprüfung mit verfügbaren lokalen Werkzeugen dokumentieren;
  bei erheblichem ungelöstem Risiko stoppen und Ingo entscheiden lassen.
- [ ] `test_contract.py` zuerst schreiben: gerenderte Ressourcen als YAML laden;
  Assertions auf genau eine Replik, Recreate, expliziten Namespace mit Restricted,
  PVC-Schutz, keine HPA/Ingress/externen Services/hostNetwork/hostPort/RBAC,
  kein SA-Token, Ressourcenlimits, non-root, kein Privilege Escalation,
  alle Capabilities entfernt und ausschließlich gepinnte Images.
  Konfiguration auf Loopback-Admin, Port 8080 und DB unter `/data` prüfen.
- [ ] Test ohne vorhandene GoPhish-Manifeste ausführen; er muss wegen fehlender
  Ressourcen fehlschlagen. In `just test` einbinden, ohne bestehende Checks zu entfernen.
- [ ] Base/Overlay und ConfigMap implementieren. Binary direkt starten statt
  `docker/run.sh`. Read-only Rootfs, nur erforderliche beschreibbare Volumes.
  Startwerte: PVC 1Gi, CPU requests/limits 100m/500m, RAM 128Mi/512Mi.
  Startup-/Readiness-/Liveness-Probes lokal prüfen; keine ausgedachte Health-Route.
- [ ] Netzwerk-Kontrakt ergänzen: Policy-Selektor trifft App, Ingress und Egress
  default-deny, keine SMTP-Erlaubnis. Port-Forward funktioniert unabhängig vom
  öffentlichen Routing; tatsächliches Cilium-Verhalten bei Abnahme prüfen.
- [ ] Bootstrap-Passwort und Token sicher generieren und direkt mit SOPS
  verschlüsseln; Secret über KSOPS laden. Der freigegebene Eigenbuild entfernt
  die Passwortausgabe direkt in `models/models.go`; der ursprüngliche
  Shell-Logfilter-Ansatz ist damit **ersetzt**, nicht zusätzlich einzubauen.
  Testfälle: konfiguriertes Passwort funktioniert und wird nicht geloggt,
  Passwortwechsel bleibt erforderlich, SIGTERM beendet den Prozess sauber.
- [ ] `test-gophish-contract.sh` mit synthetischen Daten schreiben: Start mit
  Restricted-vergleichbaren Flags, Login/erzwungener Passwortwechsel,
  Admin nicht über Container-Netz erreichbar, Landinglistener auf 8080;
  Neustart mit demselben Volume erhält Benutzer und geändertes Passwort.
  Testnetz ohne SMTP/Internet und ohne echte Empfänger.
- [ ] Statische Tests und lokalen Image-Test ausführen; bei Erfolg nur eigene
  Dateien stagen, Branch kontrollieren und Task committen.

### Task 2: Konsistentes Backup und Restore-Verfahren

**Interfaces:** Konsumiert PVC und UID/GID aus Task 1.
Produziert `gophish-backup`, tägliche SQLite-Snapshots, getrennten S3-Egress
und ein nachvollziehbares Restore-/Löschverfahren.

- [ ] Kontrakttests für täglichen CronJob, `concurrencyPolicy: Forbid`,
  eigene Pod-Labels, RWO-PodAffinity und eingeschränkten S3-Egress ergänzen.
  Ohne Backup-Manifest muss der Test fehlschlagen.
- [ ] Backup nach dem SQLite-Muster im Backup-Runbook bauen:
  gepinnter SQLite-Initcontainer erstellt `.backup` und prüft
  `PRAGMA integrity_check`; rclone lädt nur die geprüfte Kopie hoch.
  Quell-PVC nur für den Snapshot-Schritt schreibbar, gleicher App-Benutzer.
  Backup-Egress ausschließlich Garage `192.168.23.21/32:3900`.
- [ ] Eigenes Ziel `backup-gophish`, RW-Key ohne Owner-Rechte und dessen
  Provisionierung als externen Schritt dokumentieren. Keine fremden App-Keys
  wiederverwenden. Ohne echte Credentials kein Platzhalter-Secret ausrollen:
  CronJob explizit suspendieren und Abnahmeblocker dokumentieren.
- [ ] Lokalen Snapshot-Test mit synthetischer SQLite-DB unter parallelen
  Schreibzugriffen ausführen: Snapshot besteht Integritätsprüfung; beschädigte
  Kopie führt zu Fehler und keinem Upload-Aufruf.
- [ ] Retention im Backup-Code auf 30 Tage begrenzen; zusätzlich explizite
  Löschung aller Kampagnenkopien vorsehen. Die echte Löschfrist vor
  personenbezogener Nutzung abstimmen, nicht aus der Standardretention ableiten.
- [ ] Restore mit synthetischem Backup in neuem lokalen Volume testen, ohne
  Live-DB zu überschreiben. Keine Restore-Klone im produktiven Cluster.
  Tests für datierte Altstände und gültige neue Sicherung ergänzen.
- [ ] Tests ausführen, Branch prüfen, eigene Dateien committen.

### Task 3: Betriebsdoku, vollständige Prüfung und PR

**Interfaces:** Konsumiert geprüfte Ressourcen aus Task 1/2.
Produziert überprüfbaren PR und klare Trennung zwischen vorbereitet, ausgerollt
und produktionsfähig.

- [ ] Runbook und Production-Readiness aktualisieren: Loopback-Port-Forward,
  Bootstrap-Secret sicher abrufen, Passwortwechsel, Restart/PVC-Erhalt,
  Backup-Abnahme und Restore, Log-/Export-/Snapshot-Löschung.
- [ ] Abnahmeplan dokumentieren: nach freigegebenem Merge read-only
  ArgoCD/Pod/PVC/Policy prüfen; Login über Port-Forward und Erhalt der Daten
  prüfen. Kein `apply`, kein manueller Neustart, kein Testmailversand.
  Fehlende Live-Abnahme ehrlich als offen kennzeichnen.
- [ ] Für Phase 2 sperren: Domain/DNS/Zertifikate, öffentliche Landingpage,
  SMTP, echte Empfängerliste, Auftrag/Datenschutz und Kampagnenstart.
- [ ] `nix develop --command just validate` ausführen.
  Erwartet: Exitcode 0; vorhandene Baseline-Probleme getrennt ausweisen,
  nicht fremde Änderungen reparieren oder Ausnahmen verstecken.
- [ ] `nix develop --command bash scripts/render.sh apps/overlays/main/gophish`
  ausführen und Render auf Security, Resources, Exposure, PVC, Backup und
  Secrets prüfen. Falls das Skript zusätzliche Argumente verlangt, dessen
  dokumentierten Aufruf verwenden. Keine Secret-Klartexte veröffentlichen.
- [ ] Lokalen Image-/Persistenz-/Backup-Test erneut ausführen.
  Review aller Änderungen und `git diff --check`; ausschließlich eigene Dateien
  stagen, `git branch --show-current` prüfen, committen.
- [ ] Betriebsdoku zusätzlich nach
  `192.168.23.19:/root/ansible/kellerio-docs/` kopieren.
  Feature-Branch pushen und PR mit Testbelegen und offenen Gates öffnen;
  nicht selbst mergen.

## Planprüfung

Alle freigegebenen Phase-1-Anforderungen sind Tasks zugeordnet. Die fünf
Review-Fälle besitzen statische oder lokale Tests bzw. ausdrücklich
getrennte spätere Live-Abnahme. Öffentliches Routing und SMTP sind kein
Bestandteil dieser Implementierung. Ausführungsmethode und dieser Plan
werden vor Implementierungsbeginn vom Nutzer bestätigt.
