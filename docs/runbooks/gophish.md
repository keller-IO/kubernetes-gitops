# GoPhish — lokaler Eigenbuild und Freigabegates

Stand: 26.11.2026. **Noch nicht auf kellerIO installiert.**
Keine Domain, DNS-, Zertifikats- oder SMTP-Änderung; keine echten Empfängerdaten.

## Warum Eigenbuild

Das offizielle Image ist am dokumentierten Sicherheitsgate gescheitert:
[Image-Prüfung](../superpowers/specs/2026-11-25-gophish-image-security.md).
Ingo hat den eigenen Build mit aktueller Go-Toolchain und geprüften
Abhängigkeitsupdates am 26.11.2026 freigegeben.

`images/gophish/` enthält:

- `source-ref.txt`: offizieller v0.12.1-Commit, kein beweglicher Branch.
- `Containerfile`: per Digest gepinnter Go-1.27.4-Builder;
  statischer Runtime-Build, `scratch`, CA-Zertifikate, UID/GID 10001.
  Keine Shell, Paketverwaltung, Credentials oder automatisch erzeugte Zertifikate
  im Runtime-Image. Der zusätzliche `contract`-Target ist nur für lokale Tests.
- `go.mod`/`go.sum`: eingefrorene Modulversionen und Prüfsummen.
  Beim normalen Build läuft kein `go get -u`.
- `source.patch`: Bootstrap-Passwort nicht mehr im Log; korrekte explizite
  HTTP-Behandlung der neuen CSRF-Middleware; SIGTERM und normales
  `http.ErrServerClosed` beim Herunterfahren.
- Tests: Bootstrap-Logschutz, vollständige Upstream-Suite und isolierter
  Runtime-Vertrag. Zwei veraltete Testannahmen wurden ersetzt, nicht Tests
  entfernt: ZIP-Inhalte statt komprimierter Bytes; Namen und Bytes aller
  erhaltenen MIME-Anhänge statt Annahme eines vom Parser verworfenen Bildes.

Der Go-Compiler und die Module sind gepinnt; eine bitidentische
OCI-Reproduktion mit festem Layer-Zeitstempel ist **nicht nachgewiesen**.

## Bauen und prüfen

Vom Repo-Root:

```bash
nix develop --command just gophish-build /tmp/opencode/gophish-rebuild
```

Das Rezept klont ausschließlich den gepinnten Commit in einen temporären
Kontext, prüft und appliziert den Patch, lädt verifizierte Module und führt
Tests/Build anschließend ohne Netzwerk aus. Es baut nur lokale Tags:

- Runtime: `localhost/gophish-rebuild:0.12.1-go1.27.4`
- Test-Harness: `localhost/gophish-rebuild-contract:0.12.1-go1.27.4`

Der Runtime-Test läuft ohne Netzwerk, mit read-only Rootfs, ohne Capabilities,
ohne Privilege Escalation, non-root und mit CPU/RAM/PID-Limits. `/data` ist ein
flüchtiges Test-Volume. Geprüft werden Login, Passwortwechsel,
CSRF-Ablehnung für fremde Origins und fehlende Tokens, statische Assets,
API-Ablehnung ohne Key, Neustart mit gleicher Datenbank und sauberer SIGTERM.
Es werden keine E-Mails versendet.

Das Bootstrap-Modell muss das Passwortwechsel-Flag setzen. Noch offene
E2E-Testlücke: Der Runtime-Test besucht die Reset-Seite direkt und prüft nicht
zusätzlich, dass Dashboard-Zugriff vor dem Wechsel dorthin umgeleitet wird.

Artefakte:

- `gophish.oci.tar`: ausschließlich der Runtime-Target
- `gophish.docker.tar`: derselbe Runtime-Target im von Trivy unterstützten
  Docker-Archivformat; ein OCI-Tar wurde von der gepinnten Trivy-Version
  nicht akzeptiert.
- `trivy.json`: vollständiger Scan einschließlich mittlerer Befunde
- `image-id.txt`: lokale Image-ID, **kein Registry-Manifestdigest**
- `archive.sha256`: SHA-256 des OCI-Archivs

Das Scan-Gate muss eine Go-Binary erkannt haben, blockiert HIGH/CRITICAL sowie
ein erkanntes EOL-Betriebssystem und weist einen fehlenden/ungültigen Report ab.
Die Python-Gatetests laufen zusätzlich über `just test`.
**Das Rezept pusht nie und verändert keinen Cluster.**

## Verbleibender CSRF-Befund und Scan-Grenzen

Der erste erkannte Scan der aktualisierten Binary meldet keine HIGH/CRITICAL,
aber **CVE-2025-47909 (MEDIUM)** in `gorilla/csrf v1.7.3`.
Die Schwachstelle betrifft zusätzlich konfigurierte `TrustedOrigins`, die
HTTP-/HTTPS-Herkunft nicht ausreichend trennen.

Für diese interne Phase gilt:

- `trusted_origins` bleibt leer; keine zusätzliche vertrauenswürdige Domain.
- Administration ausschließlich über Pod-Loopback und authentifizierten,
  lokal auf 127.0.0.1 gebundenen Port-Forward.
- Der Runtime-Test prüft, dass gültiger Token plus fremde Origin nicht genügt.
- Keine pauschale CVE-Ausnahme/Ignore-Datei. Vor jeder Erweiterung der
  Admin-Erreichbarkeit oder TrustedOrigins erneut prüfen.

Der Scanner beweist keine umfassende Sicherheit. Vendorte Browser-Bundles und
statisch eingebettete C-Bestandteile werden nicht vollständig durch die
Go-Modulerkennung abgedeckt. Das `scratch`-Image entfernt alte Debian-Pakete;
es aktualisiert nicht automatisch den Browsercode. Upstream-Assets und
Browserfunktionalität sind vor breiter Nutzung zusätzlich zu prüfen.
Die Upstream-Templates enthalten externe Schriftart-Links; vor echter Nutzung
die daraus resultierenden Browserabrufe datenschutzseitig bewerten/entfernen.

## Noch offen vor kellerIO

1. Build und Runtime-Image-Scan sind lokal bestanden:
   [Ergebnis vom 26.11.2026](../superpowers/specs/2026-11-26-gophish-rebuild-result.md).
   Das ist keine umfassende Sicherheits- oder Deploymentfreigabe.
2. **Ersten Registry-Push/Zielregistry freigeben**, Artifact veröffentlichen,
   Registry-Manifestdigest lesend auflösen und im Deployment pinnen.
3. Namespace/Deployment/PVC/SOPS/NetworkPolicy gemäß
   [Design](../superpowers/specs/2026-11-25-gophish-internal-design.md)
   und [Plan](../superpowers/plans/2026-11-25-gophish-internal.md) ergänzen.
4. Konsistentes SQLite-Offsite-Backup mit eigenem Garage-Bucket/Key und
   Restore-Test abnehmen; kein Kampagnenbetrieb ohne fertiges Backup.
5. CI/Review/PR vor Merge. Kein eigenmächtiger Merge und keine Live-Schreibbefehle.

Domain/DNS/Zertifikate, öffentliche Landingpage, SMTP, echte Empfänger und
Kampagnenstart bleiben separat freizugeben.
