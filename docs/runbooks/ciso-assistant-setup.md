# CISO Assistant — Inbetriebnahme (VVT / GRC)

Stand: 2026-09-22. **In Betrieb seit 22.09.2026** (PR #198, Merge `15dba48`).

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
                  ├─ ciso-assistant-pg-rw  (CNPG, Backup → Garage s3://backup-ciso-assistant/cnpg/)
                  ├─ Ceph-RGW http://192.168.2.7:7480, Bucket ciso-assistant-evidence (Evidenzen)
                  └─ mx02 192.168.2.209:25 (SMTP-Relay, Absender noreply@jit-creatives.de)
```

**Nur intern erreichbar, per IP-Allowlist erzwungen.** `*.jit.services` löst
zwar auf eine RFC1918-Adresse auf, der Router leitet 443 aber auf denselben LB
`.246` weiter. Ohne Allowlist erreicht jeder mit passendem Host-Header die
App aus dem Internet. Erlaubt sind `192.168.0.0/16`, `10.0.0.0/8` und
`100.64.0.0/10` (NetBird), alles andere bekommt 403. Das funktioniert, weil
`$remote_addr` seit `externalTrafficPolicy: Local` die echte Client-IP ist und
XFF nur aus `192.168.2.0/24` geglaubt wird.

## Evidenzen auf Ceph-RGW

Anhänge liegen nicht auf einem PVC, sondern im RGW-Bucket
`ciso-assistant-evidence`. RGW läuft als einzelne Instanz auf `cloud64` und
trägt bereits GitLab, `invoices` und `jitmgmt`. Das Backend bleibt dadurch
zustandslos, und Downloads laufen mit Rechteprüfung über das Backend; Browser
greifen nie direkt auf RGW zu.

- RGW-User `ciso-assistant`: `max-buckets=1`, User-Quota 20 GiB (angelegt 22.09.2026).
  Keys in `apps/base/ciso-assistant/s3.sops.yaml`.
- Belegung: `radosgw-admin bucket stats --bucket=ciso-assistant-evidence` (auf cloud64).
- Quota ändern: `radosgw-admin quota set --quota-scope=user --uid=ciso-assistant --max-size=<n>G`.
- ⚠️ Kein Offsite-Backup. Der Bucket liegt im selben Ceph wie alles andere in Halbe.

## Mail

Versand über mx02 (`192.168.2.209:25`) per IP-Relay (`mynetworks`), genau wie bei
Mailman. Pod-Traffic wird auf die Node-IP genattet, deshalb müssen **alle**
kellerIO-Nodes in `mx_gateway_trusted_clients` stehen (cfgmgmt01
`group_vars/mx_gateways.yml`, Playbook `playbooks/mx_gateways_without_base.yml`).
wrk5 (`.88`) fehlte dort und wurde am 22.09.2026 auf mx02 und mx03 ergänzt.
**Bei jedem neuen Node nachziehen**, sonst scheitert Mail je nach Scheduling mit
`554 5.7.1 Relay access denied`.

Absender `noreply@jit-creatives.de`: SPF `include:jitcreatives.de` erlaubt
`87.191.135.42` (mx02-NAT).

## Inbetriebnahme 22.09.2026

1. Garage-Bucket und -Key für das DB-Backup: Bucket `backup-ciso-assistant`
   (20 GiB Quota), Key `backup-ciso-assistant` (`GKb113705f…`) mit RW nur auf
   diesen Bucket, verschlüsselt in `apps/base/ciso-assistant/backup-s3.sops.yaml`.
   Probe mit dem Key: PUT/GET/LIST/DELETE im eigenen Bucket 200/204, LIST/PUT auf
   `backups` 403.
2. Merge von #198, ArgoCD-Sync: nach ca. 3 Minuten `Synced/Healthy`, Zertifikat
   per DNS-01 ausgestellt, CNPG `Cluster in healthy state`, WAL-Archivierung
   (`ContinuousArchiving`) aktiv. Die erste `ScheduledBackup` läuft um 02:40.
3. Keycloak-Client `ciso-assistant` im Realm `bgt` angelegt (siehe unten). Probe:
   korrekte Redirect-URI → Login-Formular (200), fremde Redirect-URI → 400.
4. Zu Beginn gemessen (`kubectl top`, erster Start inkl. Migration): Backend
   349Mi/970m (Migration), Huey 485Mi, Frontend **375Mi** bei 512Mi-Limit,
   Postgres 51Mi.

Bekannte Anlauf-Meldungen beim allerersten Start, beide harmlos: Huey meldet
`OperationalError: connection is bad` bzw. `relation "automation_workflowinstance"
does not exist`, solange Postgres hochfährt bzw. das Backend noch migriert. Das
Backend protokolliert einmal `TypeError: issubclass() arg 1 must be a class`
aus der Warteschleife des Startskripts, bevor die DB bereit ist.

**Namensauflösung direkt nach dem Sync:** `grc.jit.services` war im LAN bis zu
einer Stunde nicht auflösbar (`NODATA` aus dem Negativ-Cache). Ursache und
Abhilfe siehe
[learnings/wildcard-dns01-empty-non-terminal.md](../learnings/wildcard-dns01-empty-non-terminal.md).

## Erster Start

- Das Backend migriert beim ersten Start die DB und lädt die Framework-Bibliothek.
  Das dauert einige Minuten.
- Lokaler Admin: E-Mail und Passwort stehen in
  `sops -d apps/base/ciso-assistant/secret.sops.yaml` (`ciso-assistant-django`).
  Er ist der Notfallzugang neben SSO; das Passwort nach dem ersten Login ändern.
- Mail testen: *Einstellungen → Allgemein* bzw. Passwort-Reset für einen
  Testbenutzer auslösen, danach auf mx02
  `grep noreply@jit-creatives.de /var/log/mail.log | tail`.
- Evidenz testen: an einer Maßnahme einen Anhang hochladen und wieder
  herunterladen, dann auf cloud64 `radosgw-admin bucket stats --bucket=ciso-assistant-evidence`
  (`num_objects` > 0).
- Wenn der Admin nach dem Login keine Administrationsrechte hat: CISO
  Assistant nimmt Superuser erst beim nächsten `migrate` in die Gruppe
  `BI-UG-ADM` auf, also beim nächsten Pod-Start. Dann einmal den Backend-Pod
  neu starten; das gibt ein Mensch mit Schreibrechten frei.

## Keycloak (OIDC)

Client `ciso-assistant` im Realm `bgt`, angelegt am 22.09.2026 per Admin-API.
Das Client-Secret liegt auf auth01 in `/root/ciso-assistant-oidc-client-secret`
(0600) und nach Repo-Konvention verschlüsselt in
`apps/base/ciso-assistant/oidc.sops.yaml` (Secret `ciso-assistant-oidc`, in keinen
Pod gemountet, weil die App SSO aus ihrer DB liest).

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

Vorgehen, weil die Zugangsdaten eines dauerhaften Admin-Service-Accounts nicht
vorliegen (siehe auth01-Doku): In `/opt/auth.savar.de` einen temporären Client
anlegen mit `docker compose run --rm --no-deps -T -e X=<secret> keycloak
bootstrap-admin service --client-id tmp-… --client-secret:env=X </dev/null`, damit
per Client-Credentials ein Token holen, den Client über
`POST /admin/realms/bgt/clients` anlegen und den temporären Client wieder löschen.

⚠️ **Das Skript nicht per `ssh host 'bash -s' < skript.sh` ausführen.**
`docker compose run` erbt dann stdin und verschluckt den Rest des Skripts. Der
erste Versuch endete so ohne Fehlermeldung direkt nach dem Container-Start und
hinterließ einen verwaisten `tmp-…`-Admin-Client im Master-Realm (beim zweiten
Lauf gelöscht). Das Skript per `scp` kopieren und als Datei ausführen, und für
`docker compose run` immer `</dev/null` setzen.

Dann in CISO Assistant unter *Einstellungen → SSO*:

- Provider: OpenID Connect
- Server URL: `https://login.jit-creatives.de/realms/bgt`
- Client ID: `ciso-assistant`, Secret: `sops -d apps/base/ciso-assistant/oidc.sops.yaml`
  (oder `ssh root@192.168.2.30 cat /root/ciso-assistant-oidc-client-secret`)

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

- **Evidenz-Bucket ohne Offsite-Kopie.** Vorschlag: nächtlicher
  `rclone sync`-CronJob RGW → Garage Potsdam (`s3://backup-ciso-assistant/evidence/`,
  mit `--backup-dir`, damit Löschungen nicht sofort mitgespiegelt werden).
  Dann die Garage-Quota (derzeit 20 GiB) um die 20 GiB der RGW-Quota erhöhen.
- **Frontend-Speicher**: 375Mi gemessen bei 192Mi Request und 512Mi Limit. Das
  Limit ist knapp, nach einer Woche Betrieb mit `kubectl top` neu messen und
  Request/Limit anheben. Huey liegt mit 485Mi über seinem Request von 384Mi.
- **SSO in der App eintragen** (Einstellungen → SSO) und mit einem Keycloak-Benutzer
  testen; danach prüfen, was ein neuer Benutzer ohne Gruppenzuweisung sieht.
- **Expliziter A-Record** `grc.jit.services` bei ClouDNS, damit künftige
  Zertifikatserneuerungen die Auflösung nicht mehr unterbrechen.
