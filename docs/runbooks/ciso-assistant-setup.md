# CISO Assistant — Inbetriebnahme (VVT / GRC)

Stand: 2026-09-22

CISO Assistant (intuitem, Community Edition, AGPL) ist das Werkzeug für das
**Verzeichnis von Verarbeitungstätigkeiten** nach Art. 30 DSGVO. Das
Privacy-Modul bildet Verarbeitungen mit Zwecken, personenbezogenen Daten,
Betroffenen, Empfängern, Auftragsverarbeitern und Drittlandtransfers ab.
Außerdem verwaltet es Betroffenenanfragen und Datenpannen. Nebenbei stehen
ISO 27001, NIS2 und DSGVO als Frameworks für TOMs und Risikoanalyse zur
Verfügung.

## Architektur

```
Browser (LAN / Potsdam / NetBird)
   │  https://grc.jit.services   (*.jit.services → 192.168.2.246)
   ↓
nginx-inc ── IP-Allowlist (server-snippets) ── TLS via cert-manager DNS-01/ClouDNS
   ├─ /      → ciso-assistant-frontend  (SvelteKit)
   └─ /api/  → ciso-assistant-backend   (Django/Gunicorn + Huey-Sidecar)
                  ├─ ciso-assistant-pg-rw  (CNPG, Backup → Garage s3://backups/cnpg-ciso-assistant/)
                  └─ PVC ciso-assistant-localstorage  (Evidenzen, ceph-rbd, RWO)
```

**Nur intern erreichbar, per IP-Allowlist erzwungen.** `*.jit.services` löst
zwar auf eine RFC1918-Adresse auf, der Router leitet 443 aber auf denselben LB
`.246` weiter. Ohne Allowlist erreicht jeder mit passendem Host-Header die
App aus dem Internet. Erlaubt sind `192.168.0.0/16`, `10.0.0.0/8` und
`100.64.0.0/10` (NetBird), alles andere bekommt 403. Das funktioniert, weil
`$remote_addr` seit `externalTrafficPolicy: Local` die echte Client-IP ist und
XFF nur aus `192.168.2.0/24` geglaubt wird.

## Vor dem Merge

1. **Garage-Key für das DB-Backup** anlegen (auf `192.168.23.21`, siehe
   [backup-restore.md](backup-restore.md)) und eintragen:
   ```bash
   G=$(docker ps -qf name=garage | head -1)
   docker exec $G /garage key create cnpg-ciso-assistant
   docker exec $G /garage bucket allow --read --write backups --key cnpg-ciso-assistant
   sops apps/base/ciso-assistant/backup-s3.sops.yaml   # REPLACE_ME ersetzen
   ```
   Ohne echte Credentials staut CNPG die WALs, bis die Disk voll ist.
2. **Keycloak-Client** im Realm `bgt` anlegen (siehe unten). Das Secret
   landet nicht in Git, es wird in der App-UI eingetragen.

## Erster Start

- Das Backend migriert beim ersten Start die DB und lädt die Framework-Bibliothek.
  Das dauert einige Minuten.
- Lokaler Admin: E-Mail und Passwort stehen in
  `sops -d apps/base/ciso-assistant/secret.sops.yaml` (`ciso-assistant-django`).
  Er ist der Notfallzugang neben SSO; das Passwort nach dem ersten Login ändern.
- Wenn der Admin nach dem Login keine Administrationsrechte hat: CISO
  Assistant nimmt Superuser erst beim nächsten `migrate` in die Gruppe
  `BI-UG-ADM` auf, also beim nächsten Pod-Start. Dann einmal den Backend-Pod
  neu starten; das gibt ein Mensch mit Schreibrechten frei.

## Keycloak (OIDC)

Client im Realm `bgt` (Admin-Konsole `https://login.jit-creatives.de`):

| Feld | Wert |
|------|------|
| Client type | OpenID Connect |
| Client ID | `ciso-assistant` |
| Client authentication | an (confidential) |
| Flows | nur Standard flow |
| Root URL | `https://grc.jit.services` |
| Home URL | `/` |
| Valid redirect URIs | `https://grc.jit.services/api/accounts/oidc/openid_connect/login/callback/` |
| Valid post logout redirect URIs | `https://grc.jit.services/login` |
| Web origins | `https://grc.jit.services` |

Dann in CISO Assistant unter *Einstellungen → SSO*:

- Provider: OpenID Connect
- Server URL: `https://login.jit-creatives.de/realms/bgt`
- Client ID / Secret: aus Keycloak (*Credentials*)

Benutzer werden beim ersten SSO-Login angelegt. Rechte vergibt ein Admin in
CISO Assistant über Benutzergruppen; nach dem ersten SSO-Login prüfen, was ein
neuer Benutzer ohne Zuweisung sieht.

## Prüfen

```bash
# intern: 200 bzw. Redirect auf /login
curl -sI https://grc.jit.services/ | head -1
# von außen (über die WAN-IP, Host-Header gesetzt) — muss 403 liefern:
curl -skI --resolve grc.jit.services:443:87.191.135.42 https://grc.jit.services/ | head -1
```

Den zweiten Test von einem Host außerhalb aller erlaubten Netze ausführen,
etwa über Mobilfunk. Innerhalb des LANs gilt wegen Hairpin-NAT die interne
Quelladresse.

## Offen

- **SMTP** ist nicht konfiguriert (Chart-Default `smtp.server.local`).
  Passwort-Reset-Mails und Benachrichtigungen funktionieren erst mit einem
  Relay; dafür `backend.config.smtp.*` und ein `existingSecret` setzen.
- **Evidenz-PVC** `ciso-assistant-localstorage` liegt nicht im CNPG-Backup.
  Vor produktiver Nutzung einen VolumeSnapshot-/Offsite-Weg festlegen, siehe
  [backup-restore.md](backup-restore.md) (RBD-PVC-Snapshots).
- **Resources** sind Startwerte ohne Messung; nach einer Woche per
  `kubectl top` nachziehen.
