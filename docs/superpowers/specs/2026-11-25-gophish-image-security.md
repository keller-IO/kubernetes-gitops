# GoPhish — Image-Prüfung blockiert Rollout

Stand: 25.11.2026. Status: **Sicherheitsgate geschlossen**, keine
GoPhish-Manifeste ausgerollt, keine Secrets erzeugt, keine Mails versendet.

## Geprüftes Artefakt

- Repository: `docker.io/gophish/gophish`
- Tag: `0.12.1`
- Digest: `sha256:8a57cd171999dcd1fa33f346d6898440913ae14be114ffc850cc678354672d29`
- Architektur: Linux/amd64
- Erstellungsdatum laut Registry: 30.11.2022
- Arbeitsverzeichnis: `/opt/gophish`, Benutzer laut Image-Konfiguration: `app`
- Scanner: Trivy aus dem gepinnten Nix-Dev-Shell, aktuelle Vulnerability-DB
  am 25.11.2026 geladen; Scan über Registry ohne Ausführung des Images.

Reproduzierbar mit:

```bash
nix develop --command trivy image --image-src remote --scanners vuln \
  --format json --output /tmp/opencode/gophish-image-vulnerabilities.json \
  docker.io/gophish/gophish@sha256:8a57cd171999dcd1fa33f346d6898440913ae14be114ffc850cc678354672d29
```

## Ergebnis

| Bereich | Kritisch | Hoch | Mittel | Niedrig | Unbekannt |
| --- | ---: | ---: | ---: | ---: | ---: |
| Debian-Pakete | 12 | 197 | 245 | 166 | 25 |
| Go-Binary | 5 | 107 | 93 | 5 | 3 |
| Summe | 17 | 304 | 338 | 171 | 28 |

Das sind Paket-/Komponentenbefunde, keine deduplizierte Zahl ausnutzbarer
Schwachstellen. Gleiche CVEs können mehrere Komponenten betreffen.
Erreichbarkeit der betroffenen Funktionen wurde nicht nachgewiesen.
Trivy identifiziert Debian 11.5 als EOSL und warnt vor unvollständiger Erkennung.

Die Binary enthält laut Scanner Go-Standardbibliothek **v1.15.2** sowie
alte `golang.org/x/net`- und `golang.org/x/crypto`-Abhängigkeiten.
Beispiele für gemeldete Befunde:

- CVE-2023-24538 / CVE-2023-24540: kritische `html/template`-Befunde.
- CVE-2022-41725: hohe Ressourcenverbrauchs-/DoS-Schwachstelle in
  `net/http` und `mime/multipart`.
- CVE-2023-39325 / CVE-2023-45288: hohe HTTP/2-DoS-Befunde;
  Relevanz hängt von tatsächlich aktivierten Protokollen ab.

Ein modernes Basisimage allein behebt die eingebetteten Go-Komponenten nicht.
Non-root, Loopback-Administration und NetworkPolicies begrenzen Exposition,
ersetzen aber keine Prüfung oder Aktualisierung der betroffenen Software.

## Entscheidung nötig

Gemäß freigegebenem Plan Task 1 vor weiteren Implementierungsschritten
angehalten. Empfehlung: einen reproduzierbaren eigenen Build mit gepflegter
Go-Toolchain, aktuellem Runtime-Basisimage und geprüften
Abhängigkeitsupdates untersuchen. Das ist eine Änderung der Image-Strategie,
keine bereits bewiesene Lösung; erneuter Scan und Funktionstests bleiben nötig.

Keine pauschale CVE-Ausnahme und kein Ausrollen des alten Images.
Nach Freigabe zuerst Buildbarkeit und verbleibende Sicherheitsbefunde prüfen,
danach den bestehenden Deployment-/Backup-Plan fortsetzen.

Der vollständige JSON-Scan liegt im lokalen, gitignorierten Plan-Workspace
unter `.superpowers/sdd/2026-11-25-gophish-internal/image-vulnerabilities.json`.
