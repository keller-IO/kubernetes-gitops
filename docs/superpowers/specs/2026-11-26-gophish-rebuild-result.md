# GoPhish-Eigenbuild — Prüfergebnis 26.11.2026

**Eigenbuild lokal bestanden; noch nicht veröffentlicht oder auf kellerIO
installiert.** Keine echten Empfänger, keine Domains/DNS/Zertifikate/SMTP geändert.

## Identität und Nachbau

- Upstream v0.12.1, Commit
  `b1648f0759c6d57ac989157c55d8b47c40254fe6`.
- Go 1.27.4/trixie, Builder-Digest
  `sha256:430985542100b871e108ccc00e8dcc5eef08ca14ee5825e98ebf563d8ffec4ee`.
- Gepinnte Module und Source-Patch in `images/gophish/`.
- Lokaler Tag `localhost/gophish-rebuild:0.12.1-go1.27.4`.
- Runtime-Image-Konfigurations-ID:
  `sha256:07eff89ea64fb362fa8eddf28da3775efc20e8a3aa90bb7ba5145577776d9362`.
- Lokaler OCI-Manifestdigest:
  `sha256:3ec92fdbd0436b71aaf66c9c23002560e82b1a8a9f839960501b769d64ea1ceb`.
  Das ist **noch kein in einer Registry veröffentlichter Digest**.

Nachbau: `nix develop --command just gophish-build /tmp/opencode/gophish-rebuild`.
Quellen/Module/Builder sind fixiert; bitidentische OCI-Reproduktion ist nicht
nachgewiesen.

## Belege

- Build aus frischem, exakt gepinntem Source-Checkout, Modulprüfung und gesamte
  Upstream-Go-Suite: bestanden. Tests und Kompilierung ohne Netzwerk.
- Runtime-Test des neuen `scratch`-Containers: bestanden, mit UID 10001,
  read-only Rootfs, ohne Netzwerk/Capabilities, mit CPU/RAM/PID-Limits.
  Login, Passwortwechsel, CSRF-Ablehnung, Assets, API ohne Key, Neustart mit
  unverändertem Passwort, keine Passwortwerte im Log und sauberer SIGTERM.
- Regression Bootstrap-Passwort im Log: vor Source-Fix fehlgeschlagen,
  danach bestanden. SIGTERM-Runtime-Test ebenfalls RED → GREEN.
- Sechs Scan-Gatetests: bestanden; fehlende Go-Erkennung und
  HIGH/CRITICAL/EOL/ungültige Reports werden blockiert.
- `nix develop --command just validate`: bestanden.
- Unabhängiges Code-Review: keine Critical/Important-Codebefunde;
  widersprüchliche alte Logfilter-Anweisungen anschließend berichtigt.

## Scan des vollständigen Runtime-Images

Trivy hat im tatsächlich exportierten Runtime-Image die Go-Binary erkannt:

| Schwere | Befunde |
| --- | ---: |
| CRITICAL | 0 |
| HIGH | 0 |
| MEDIUM | 1 |

Der mittlere Befund ist **CVE-2025-47909**, `github.com/gorilla/csrf v1.7.3`.
Keine pauschale Ignore-Regel: volle Meldung bleibt im Report. Interne Phase
nur mit leerer `trusted_origins`-Liste; fremde Origin mit gültigem Token wird
im Runtime-Test abgelehnt. Änderungen daran brauchen erneute Bewertung.
Vendorte Browser-Bundles und eingebettete C-Komponenten sind nicht umfassend
durch die Go-Erkennung geprüft; siehe [Runbook](../../runbooks/gophish.md).

Scan/Input: Docker-Archiv desselben Runtime-Images; die gepinnte Trivy-Version
akzeptierte das OCI-Tar nicht. OCI-Export erst nach bestandenem Scan-Gate.
Lokale Detailbelege liegen unter
`.superpowers/sdd/2026-11-25-gophish-internal/rebuild-output/`.

## Bewusst offene Punkte

- Minor aus Review: Runtime-Test prüft das Bootstrap-Flag und führt Reset durch,
  aber prüft die Dashboard-Umleitung vor dem Reset noch nicht separat.
- Versionsübergreifende DB-Upgrades nicht getestet; es existiert noch keine
  produktive GoPhish-Datenbank.
- Registry-Veröffentlichung, Kubernetes-Manifeste, Backup/Restore, Retention,
  tatsächliche Netzwerkisolation und Ressourcenmessung im Cluster stehen aus.
- Öffentliche Landingpage, Domains/DNS/Zertifikate, SMTP und Kampagnenstart
  bleiben separat freizugeben.
