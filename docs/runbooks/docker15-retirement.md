# Abschaltplan fuer docker15 (192.168.2.15)

Status: Phase 1 inventarisiert und bereinigt; Phase 2 vorbereitet, aber weiterhin
NICHT ausgerollt. Zielbild am 11.09.2026 bestaetigt.

Planstand: 2026-09-11 (Live-Nachinventur; vorherige Staende 2026-09-01 und
2026-07-30).

## Statusrevision 11.09.2026

### Entscheidungen

| Frage | Entscheidung 11.09.2026 |
|---|---|
| Zielbild | **Bleibt:** Internet → UDM → nginx-inc `192.168.2.246`, TLS per cert-manager im Cluster. |
| CrowdSec | **Kein hartes Gate mehr.** Phase 4 ist empfohlen, blockiert den Cutover aber nicht. |
| `tools.kniff.eu`, `netbox.kniff.eu` | Am 11.09.2026 mit kniff01 nach victorianix umgezogen, laufen ueber edge01. Nicht mehr Teil dieses Plans. |
| `cloud-dev.savar.de` | **Bleibt** und wird mitmigriert (Backend `nc01-dev` war am 11.09. nicht erreichbar). |
| `home.savar.de` | **Dashboard entfaellt.** Der DNS-Name bleibt: `www.gemeinsam-fuer-halbe.de`, `phpmyadmin.jit-creatives.de`, `umdiehand.jit-creatives.de` und `gesinefranze.jit-creatives.de` zeigen per CNAME darauf. |
| WAN-Port 8080 (Icecast) | **Bleibt offen**, nicht Teil des Cutovers. |
| Potsdam-DR-Edge | **Aktualisieren**, siehe Abschnitt „DR-Edge Potsdam“. |

Verworfene Alternativen (bewertet am 11.09.2026, hier nur zur Nachvollziehbarkeit):

- **Neue Traefik-Edge-VM in Halbe** (Rolle `traefik_edge`, 1:1-Ersatz fuer `.15`):
  schnell und risikoarm, erreicht aber das Zielbild „direkt in den Cluster“ nicht.
- **Web ueber edge01 (victorianix) plus NetBird nach Halbe:** victorianix erreicht
  `.246` heute nicht; Router-Peers sind `cloud59`/`pve`; `jit.cloud` und S3 wuerden
  doppelt ueber WAN laufen; victorianix traegt schon dns01, web03 und GitLab.

### Am 11.09.2026 erledigt

| Schritt | Ergebnis |
|---|---|
| Umgezogene und tote Router auf `.15` entfernt | 9 Router, 11 Services (Backup `dynamic_conf.yml.bak-20260911-cleanup`). Inode unveraendert; alle 22 verbleibenden Hosts liefern vorher/nachher identische Statuscodes; keine Traefik-Fehler. |
| Cluster-Gegenstueck | PR #143 gemergt (`1bb654c`): `legacy-proxy` gitlab, gitlab-registry, aios, aios-test und die App `binaergewitter` entfernt. `app-legacy-proxy` manuell mit Prune gesynct (`Synced/Healthy`), 4 EndpointSlices geloescht, Namespace `binaergewitter` weg; alle verbleibenden Hosts ueber `.15` mit unveraenderten Statuscodes. |
| Toter CrowdSec-Bouncer auf `.15` | `crowdsec-firewall-bouncer.service` (LAPI `192.168.2.17:8087`, seit dem GitLab-Umzug unerreichbar) gestoppt und deaktiviert. Der nc05-Bouncer laeuft weiter. |
| Haengende HTTP-01-Challenges | Die verwaisten `Certificate/wordpress-tls` in `wordpress-1`/`wordpress-2` (nicht in Git, von keinem Ingress referenziert) geloescht. Alle vier Challenges nach 53 Tagen weg, keine `cm-acme-http-solver`-Ingresses mehr. |
| UDM-NAT-Ist-Stand | Per SSH ueber `pve` gelesen (`iptables -t nat`), in Phase 6 dokumentiert. |
| Legacy-Datenbanken | Alle vier gedumpt, age-verschluesselt nach Garage-S3 Potsdam, Test-Restore mit identischen Zeilenzahlen (Phase 7). Container gestoppt, `restart=no`, Daten bleiben. Aufbewahrung der Dumps 1 Jahr (bis 11.09.2027). |
| Postfix auf `.15` | Gestoppt und deaktiviert (0 Verbindungen, Queue leer, keine Logzeile seit 10.08.; mx02 liefert direkt an `.247`, zuletzt verifiziert 02.09.). |

Entfernte Router und warum:

| Host | Grund |
|---|---|
| `gitlab.jit-creatives.de`, `registry.jit-creatives.de`, `registry.savar.de` | seit 26.08.2026 auf edge01 (88.198.107.9), Backend `.17` abgeschaltet |
| `comments/search/download/pad/plan/etherpad.binaergewitter.de`, `podcast.savar.de` | seit 28.08.2026 auf edge01, Backend `.66` ohne Verkehr |
| `tools.kniff.eu`, `netbox.kniff.eu` | seit 11.09.2026 auf edge01, Backend `.29` abgeschaltet |
| `www.aios.tools` | DNS zeigt extern (`95.216.69.123`) |
| `test.aios.tools` | Backend `192.168.2.26:8181` antwortet nicht |
| Service-Leichen `example_service` (`.17`), `redmine_service` (`.18`), `binaergewitter_dl_service` | ohne Router |

Damit entfallen fuer den Cluster: der Cloudflare-Solver (keine Cluster-Zone mehr
bei Cloudflare), die GitLab-Registry-Tests und `binaergewitter.de`, `aios.tools`,
`kniff.eu` aus der Zonenliste.

### Unveraendert gegenueber 01.09.2026

| Bereich | Live-Befund 11.09.2026 |
|---|---|
| ArgoCD | Nur `root` hat `syncPolicy.automated` (38 Applications). OutOfSync/Degraded unveraendert: `app-mastodon`, `app-nextcloud-yealink-phonebook`, `infra-cilium`, `infra-cnpg`, `infra-mariadb-operator`, `infra-monitoring`. |
| Cilium | `v1.16.5`, globale `default-l2`-Policy, Pool `default-pool` (2 frei). |
| nginx-LB | `.246` live, aber **nicht deklarativ gepinnt** (`loadBalancerIP`/`lbipam.cilium.io/ips` leer). `externalTrafficPolicy: Cluster`. Mailman `.247` ist gepinnt. |
| Real-IP | `set-real-ip-from: 192.168.2.0/24`, `real-ip-header: X-Forwarded-For` — nach dem Direkt-Cutover spoofbar. |
| CrowdSec im Cluster | Agents + LAPI, kein Bouncer. |
| cert-manager | nur `letsencrypt-prod`; PRs #79/#80 seit 30.07. offen. |

### Neue Befunde 11.09.2026

1. **steinba.ch-Mailzertifikat haengt an Traefik.** Der Router
   `steinbach_cert_router` existiert nur, damit Traefik per HTTP-01 ein Zertifikat
   fuer `imap/pop/smtp.steinba.ch` holt (Zone bei hosttech, kein DNS-01). Der Cron
   `/usr/local/sbin/steinbach-cert-deploy.sh` (taeglich 04:17) extrahiert es aus
   `acme_letsencrypt.json` und verteilt es an mail05 (`192.168.2.34`, SNI-Maps).
   Aktuelles Zertifikat gueltig bis **04.12.2026**. Ohne Ersatz scheitert die
   naechste Erneuerung, sobald Port 80 nicht mehr auf `.15` zeigt. → neuer Abschnitt
   in Phase 2 und Gate.
2. **WAN-Port 8080 ist offen** und liefert `Icecast 2.4.4` (vermutlich `.240`,
   horads). Nicht Teil der `.15`-Kette, aber bisher in keinem Inventar; beim
   UDM-Export mit aufnehmen. **Entscheidung 11.09.: bleibt offen.**
3. **`.15` ist VM 107 auf `pve`** (8,5 GiB). `pve` liegt bei 85 % RAM, 4 Kernen und
   zwei OSDs — die Abschaltung entlastet genau den schwaechsten Node.
4. **Kein Host hat AAAA-Records** (alle 57 Namen am 11.09. ueber `1.1.1.1` geprueft).
   Das IPv6-Gate ist damit erfuellt.
5. **Mail-Pfad ist bereits umgestellt:** mx02 liefert Listenmail empfaengergenau
   direkt an `lmtp:[192.168.2.247]:8024`. WAN-Port 2525 ist von aussen geschlossen.
   Postfix auf `.15` hat seit dem 10.08. keine Verbindung. mx02 fuehrt `.15` aber
   noch in `mynetworks`.
6. **Der Kalt-Standby `traefik-edge-potsdam` war veraltet** (`host_vars` auf `.17`, `.66`,
   `.29`, `.242`). Am 11.09. neu erzeugt; der Rollout scheitert an einem IP-Konflikt auf
   `192.168.23.20`. Siehe „DR-Edge Potsdam“.
7. **Echte Client-IP bleibt Pflicht, auch ohne CrowdSec.** Ohne sie sehen Nextcloud
   (`jit.cloud`), Roundcube und `auth.savar.de` alle Clients als Node-IP: deren
   Brute-Force-Drosselung trifft dann alle Nutzer gleichzeitig. Phase 3 bleibt
   deshalb hartes Gate.
8. Weitere tote bzw. zweifelhafte Eintraege, die eine Entscheidung brauchen:
   `cloud-dev.savar.de` (502, `nc01-dev` `.220` am 11.09. nicht erreichbar — bleibt),
   `db.imcor.de`, `config.imcor.de`, `www.jonaks.com` (kein A-Record), der wirkungslose
   Router `roundcube` (Fallback auf `prometheus.radiotux.de:9001`, von
   `jitmail_roundcube_router` mit Prioritaet 1000 immer ueberstimmt) und die
   Middleware `cors-headers` (nur noch ungenutzt).
9. **Sieben veraltete UDM-Portfreigaben** zeigen auf abgeschaltete oder umgezogene Ziele
   (`.17`, `.29`, `.66`, `.15`-FTP/-Registry), siehe Phase 6. Wird eine dieser IPs per DHCP
   neu vergeben, landet Internetverkehr auf einem fremden Geraet.

## Naechste Schritte

### Sofort, unabhaengig vom Cutover

1. ~~PR #143 mergen und nacharbeiten~~ — erledigt 11.09.2026.
2. ~~Legacy-Datenbanken sichern~~ — erledigt 11.09.2026 (Phase 7). Offen nur die
   Aufbewahrungsfrist (Review-Frage 6).
3. **steinba.ch-Mailzertifikat umbauen** (siehe Phase 2). Muss vor dem Port-80-
   Cutover stehen und vor Anfang November 2026 funktionieren (Renewal-Fenster fuer
   den Ablauf am 04.12.2026).
4. ~~Offene Hosts entscheiden~~ — erledigt. Die imcor/jonaks-Namen bleiben; `db.imcor.de`,
   `config.imcor.de` und `www.jonaks.com` haben seit 11.09. A-Records (87.191.135.42).
   `cloud-dev.savar.de` bleibt. Das `home.savar.de`-Dashboard entfaellt: Es haengt als
   Docker-Label am Traefik-Container und verschwindet mit dem Traefik-Stopp in Phase 8.
   Vorzeitig entfernen hiesse, den Container neu zu erzeugen (kurze Unterbrechung aller
   `.15`-Hosts). Der DNS-Name `home.savar.de` bleibt als CNAME-Ziel bestehen.
5. **UDM:** Ist-Stand der NAT-Regeln am 11.09. gelesen und in Phase 6 eingetragen. Offen:
   UniFi-Konfigurationsexport als Rollback-Beleg und das Entfernen der sieben veralteten
   Portfreigaben im Controller (nicht per SSH, der Controller ueberschreibt das).

### Vor dem naechsten Ausrollschritt

6. **ArgoCD-Freeze aufloesen** und die sechs Apps bereinigen. Ohne diesen Schritt
   rollt ein Merge nichts aus und ein Git-Revert repariert nichts.
7. **PRs #79/#80 nach #143 neu aufsetzen.** Beide Branches liegen hinter `main` und
   enthalten TLS-Aenderungen fuer die entfernten Ingresses sowie den
   Cloudflare-Solver samt `cloudflare-api-key`. Rebase auf `main`, beides entfernen,
   Manifeste gegen cert-manager `v1.21.1` validieren.
8. **Staging zuerst.** `letsencrypt-staging` und die DNS-01-Solver ausrollen, die mit
   „Staging ausstehend“ markierten Namen durchtesten. Der Catch-all-HTTP01-Solver
   wird entfernt bzw. auf `horads.de` und `steinba.ch` begrenzt.

### Weiterhin offen und entscheidungsbeduerftig

9. **Phase 3 Plattformentscheidung** (Cilium DSR/Hybrid gegen endpoint-aware L2),
   gemeinsam mit dem anstehenden Cilium-Update auf `1.20.0`. Groesster Einzelposten,
   Voraussetzung fuer den WAN-Cutover.
10. **`cloud.naturkindergarten-moehringen.de`**: CNAME beim Provider anlegen lassen
    oder den Namen aus dem Zertifikat nehmen.
11. **Potsdam-DR-Edge** fertigstellen (Entscheidung: aktualisieren), siehe „DR-Edge Potsdam“.
12. Optional: **Phase 4 CrowdSec-Enforcement** im neuen Pfad.

Ein WAN-Cutover-Termin wird erst nach Schritt 6 bis 9 sinnvoll gesetzt.

## Zielbild

```text
Internet -> UDM 192.168.2.94 -> nginx-inc 192.168.2.246
         -> Cluster-Workloads
         -> legacy-proxy -> externe Backends im LAN
```

Der Potsdam-Edge ist kein Bestandteil dieses Produktionspfads, sondern der
Disaster-Recovery-Edge (siehe „DR-Edge Potsdam“).

Meilensteine:

1. Direkten Web-Traffic auf `192.168.2.246` vorbereiten und umstellen.
2. Nicht-Web-Aufgaben von `192.168.2.15` entfernen (steinba.ch-Zertifikat, Postfix,
   Datenbanken).
3. Die VM nach Beobachtungs- und Rollback-Frist abschalten.

## DR-Edge Potsdam (CT 8020 auf u22)

Entscheidung 11.09.2026: aktualisieren.

Stand 11.09.2026:

- `host_vars/traefik-edge-potsdam.yml` (cfgmgmt01) neu aus der Live-Konfiguration von
  `.15` erzeugt: 19 Router, 19 Services, strukturell identisch zu `.15` ohne
  `steinbach_cert_router` (Mailzertifikat, Cron nur auf `.15`) und den wirkungslosen
  `roundcube`-Router. Backup `.bak-20260911`.
- Rolle `traefik_edge`: neuer Schalter `traefik_edge_dashboard_enabled` (Default `true`),
  Potsdam setzt `false`. edge01 per `--check --diff` unveraendert.
- **Rollout blockiert durch IP-Konflikt.** `192.168.23.20` ist an ein anderes Geraet
  vergeben (`espressif.localdomain`, MAC `bc:ff:4d:8e:4f:52`, vermutlich DHCP der UCG seit
  dem Routertausch am 04.09.). Beim Probestart antworteten abwechselnd CT und ESP-Geraet;
  Ansible brach mit `Connection refused` ab. CT wieder gestoppt, nichts ausgerollt.

Vor dem Rollout: feste IP ausserhalb des UCG-DHCP-Bereichs oder Reservierung. Bei einem
IP-Wechsel betroffen: CT-`net0`, Inventar `hosts`, `gitlab01_crowdsec_potsdam_bouncer_host`,
`nc05_crowdsec_potsdam_bouncer_host`, ADR `0003-crowdsec-at-k8s-ingress.md`.

DR-Luecken unabhaengig vom Rollout:

- Keine UCG-Portfreigabe 80/443 zum Edge. Im DR-Fall zusaetzlich DNS auf `176.94.125.87`
  umstellen; erst dann kann HTTP-01 Zertifikate ausstellen.
- ~~Aus Potsdam nicht erreichbar: S3, auth, jit.cloud~~ — Messfehler durch den IP-Konflikt
  (Antworten gingen teils an das ESP-Geraet). Von cfgmgmt01 (`192.168.23.19`) sind am 11.09.
  alle Backends erreichbar; nc05 erlaubt `192.168.23.20` ausdruecklich.
- Der CrowdSec-Bouncer auf dem CT zeigt noch auf die tote GitLab-LAPI `.17` (Restart-Schleife).
  Kein Gate; wie bei edge01 umstellen oder deaktivieren.
- Nach dem `.246`-Cutover laesst sich der DR-Edge stark vereinfachen (TCP-Passthrough 443 →
  `.246`), weil der Cluster TLS dann selbst terminiert.

## Aktueller Bestand auf docker15

Stand 11.09.2026:

| Aufgabe | Zustand | Abschaltbedingung | Restarbeit |
|---|---|---|---|
| Traefik | TCP 80/443, 21 Router fuer die verbleibenden Legacy-Hosts | Alle Hosts, Zertifikate und Sonderregeln auf nginx-inc verifiziert | Phase 2–6 |
| steinba.ch-Mailzertifikat | Traefik-Router + Cron nach mail05 | Ersatzkette im Cluster liefert und verteilt ein gueltiges Zertifikat | neu, offen |
| Postfix | **gestoppt und deaktiviert 11.09.**; mx02 liefert direkt an `.247` | keine produktive Verbindung, Queue leer | ab 18.09.: `.15` aus `mynetworks`/`sign_networks` |
| CrowdSec | nc05-Bouncer aktiv, GitLab-Bouncer seit 11.09. deaktiviert | kein Gate | optional Ersatz (Phase 4) |
| Mailman-Postgres | **gestoppt 11.09.** (`restart=no`), Daten erhalten | Archiv + Ende der Rollback-Frist | gesichert + Restore geprueft; Dumps bis 11.09.2027 |
| WordPress-MariaDBs | **gestoppt 11.09.** (`restart=no`), Daten erhalten | Dumps, Aufbewahrung | gesichert + Restore geprueft; Dumps bis 11.09.2027 |
| XWiki-MySQL (`db`) | **gestoppt 11.09.** (`restart=no`); Datenbank leer (0 Tabellen) | Dump, Aufbewahrung | gesichert; Dump bis 11.09.2027 |

Daneben liegen rund 20 gestoppte Container-Leichen (paperless, mailman-web/-core,
odoo, mastodon-db, nextcloud-db, wg-easy, xwiki u. a.). Sie haben keinen Einfluss
auf den Cutover und verschwinden mit der VM; ihre Volumes werden vor dem Loeschen
der VM nur dann gesichert, wenn Schritt 2 sie als relevant einstuft.

### Hostmatrix (verbleibende Router auf `.15`)

| Host(s) | Backend | Backend 11.09. | Cluster-Ingress | Solver | Disposition |
|---|---|---|---|---|---|
| `imap/pop/smtp.steinba.ch` | Zertifikatssenke | — | fehlt | HTTP-01 | migrieren, Sonderfall (Phase 2) |
| `www.`/`jugendbeauftragter-halbe.de` | `.246` | ok | `wordpress-1/wordpress` | RFC2136 | migrieren |
| `lists.jitmail.de` | `.246` | ok | `mailman/mailman` | RFC2136 | migrieren |
| `www.`/`gemeinsam-fuer-halbe.de` | `.246` | ok | `wordpress-2/wordpress` | RFC2136 | migrieren |
| `kimai.savar.de` | `.246` | ok | `kimai/kimai` | RFC2136 | migrieren |
| `paperless.savar.de` | `.246` | ok | `paperless-ngx` | RFC2136 | migrieren |
| `status.jit-creatives.de` | `.246` | ok | `gatus-public` | RFC2136 | migrieren |
| `expense.porga.de` | `.246` | ok | `expense-tracker` | RFC2136 | migrieren (Zone porga.de in Matrix aufnehmen) |
| `phpmyadmin.savar.de`, `phpmyadmin.jit-creatives.de` | `.246` | ok | `phpmyadmin` | RFC2136 | migrieren |
| `roundcube.savar.de`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de`, `webmail.daec-berlin.de` | `.246` | ok | `roundcube-jitmail` | RFC2136 | migrieren |
| `mail.steinba.ch` | `.246` | ok | `roundcube-jitmail` | HTTP-01 in-place | migrieren |
| `www.jit-creatives.de`, `mgmt02.`, `ftp.jit-creatives.de`, `www.jitcreatives.de` | `.234:80` | ok | `legacy-proxy/mgmt02` | RFC2136 | migrieren |
| `umdiehand.`, `gesinefranze.jit-creatives.de` | `.20:80` | ok | `legacy-proxy/umdiehand` | RFC2136 | migrieren |
| `stream.horads.de` | `.240:8080` | ok | `legacy-proxy/horads` | HTTP-01 in-place | migrieren |
| `spam.savar.de` | `.230:80` | ok | `legacy-proxy/spam` | RFC2136 | migrieren |
| `imcor.de`, `www.imcor.de`, `jonaks.com` | `https .21:443` | ok | `legacy-proxy/imcor` | RFC2136 Follow | migrieren |
| `db.imcor.de`, `config.imcor.de`, `www.jonaks.com` | `https .21:443` | ok | `legacy-proxy/imcor` | RFC2136 Follow | migrieren (A-Records seit 11.09.) |
| `s3.savar.de`, `s3.jit-creatives.de` | `.6/.7/.8:7480` | ok | `legacy-proxy/s3` | RFC2136 | migrieren |
| `auth.savar.de`, `auth2.savar.de` | `.30:8080` | ok | `legacy-proxy/auth` | RFC2136 | migrieren |
| `office.savar.de` | `.246` (Collabora im Cluster) | ok | `collabora-office-savar` | RFC2136 | migrieren |
| `cloud.savar.de`, `jit.cloud`, `cloud.daec-berlin.de` | `https .217` | ok | `legacy-proxy/jitcloud` | RFC2136 | migrieren |
| `cloud.steinba.ch` | `https .217` | ok | `legacy-proxy/jitcloud` | HTTP-01 in-place | migrieren |
| `cloud.naturkindergarten-moehringen.de` | `https .217` | ok | `legacy-proxy/jitcloud` | RFC2136 Follow | blockiert (CNAME fehlt) |
| `cloud-dev.savar.de` | `.246` → `.220` | **tot (502)** | `legacy-proxy/cloud-dev` | RFC2136 | migrieren (bleibt) |
| `home.savar.de` | Traefik-Dashboard | — | — | — | abkuendigen (DNS-Name bleibt als CNAME-Ziel) |
| (Router `roundcube`) | `prometheus.radiotux.de:9001` | — | — | — | entfaellt, wirkungslos |

Die Abnahme-Felder (Testpfad, Erwartung, Owner, Sign-off) werden vor der
Ausfuehrungsfreigabe ergaenzt (Phase 5).

## Harte Freigabe-Gates

Kein WAN-Cutover, solange eines dieser Gates offen ist:

- [ ] Der fleet-weite ArgoCD-Auto-Sync-Freeze ist aufgehoben und alle betroffenen
      Applications stehen `Synced/Healthy`.
- [ ] nginx-inc besitzt deklarativ und stabil `192.168.2.246`.
- [ ] Jeder produktive Traefik-Host existiert als akzeptierter Cluster-Ingress oder
      ist ausdruecklich zur Abschaltung freigegeben (Hostmatrix ohne „entscheiden“).
- [ ] Jedes SNI hat auf `.246:443` ein gueltiges, `Ready=True`-Zertifikat.
- [ ] Eine versionierte Host-zu-Solver-Matrix deckt jedes Zertifikat ab; Challenge-Typ
      und Solver stimmen ueberein. Der Catch-all-HTTP01-Solver ist begrenzt oder entfernt.
- [ ] Die steinba.ch-Mailzertifikatskette laeuft ohne `.15` und wurde einmal
      vollstaendig bis mail05 durchgespielt.
- [ ] Kein Ingress hat ein `Rejected`-Event.
- [ ] Alle manuell verwalteten EndpointSlices existieren mit korrekter Adresse, Port
      und Ready-Condition.
- [ ] Die echte externe Client-IP bleibt ohne Vertrauen in beliebige Client-XFF
      erhalten; ein Spoof-Test ist negativ.
- [ ] Die vollstaendige Anwendungs-Abnahmematrix ist erfolgreich.
- [ ] UDM-Rollback und Git-Rollback sind vorbereitet und widersprechen sich nicht bei
      HTTPS-Redirects.
- [x] Fuer jeden Host sind IPv4 und IPv6 inventarisiert; kein produktives AAAA
      (11.09.2026).
- [x] Es haengen keine `pending`-Challenges und keine verwaisten
      `cm-acme-http-solver`-Ingresses mehr im Cluster (11.09.2026).

Empfohlen, aber **kein Gate** (Entscheidung 11.09.2026):

- [ ] CrowdSec- oder gleichwertiges Edge-Enforcement im neuen Pfad (Phase 4).

## Phase 1: Live-Router vollstaendig abbilden

Erledigt bis auf die Einzelentscheidungen in der Hostmatrix. Ausgangsliste bleibt
`/opt/containers/traefik/data/dynamic_conf.yml` (Stand nach Bereinigung: 21 Router,
23 Services). Die Docker-Labels tragen nur noch den Dashboard-Router `home.savar.de`.

Die `legacy-proxy`-Services bleiben selectorlos. Ihre EndpointSlices sind von ArgoCD
ausgeschlossen und muessen vor dem Cutover live gegen die Manifeste abgeglichen werden.

**Achtung beim Bearbeiten der Datei auf `.15`:** Sie ist als Einzeldatei in den
Container gemountet. Nur in-place schreiben (`cat neu > dynamic_conf.yml`), nie per
`mv`/`sed -i` ersetzen — sonst sieht der Container die alte Inode. Vorher lokal mit
PyYAML validieren (auf `.15` nicht installiert); ein YAML-Fehler laesst Traefik die
komplette Datei verwerfen (siehe `dynamic_conf.yml.KAPUTT-20260905`).

## Phase 2: DNS-01 und Cluster-Zertifikate

TLS terminiert nach dem Cutover an nginx-inc. Zertifikate werden neu durch
cert-manager ausgestellt; Traefik-ACME-Dateien werden nicht importiert.

### Solver-Strategie

1. `jit.services` bleibt beim vorhandenen ClouDNS-DNS-01-Webhook.
2. Auf `dns01.jit-creatives.de` autoritative Zonen werden ueber RFC2136 und das
   SOPS-Secret `rfc2136-tsig` bedient.
3. `imcor.de`, `jonaks.com` und `naturkindergarten-moehringen.de` delegieren
   `_acme-challenge` per CNAME auf `acme.jit-creatives.de`; der Solver verwendet
   `cnameStrategy: Follow`.
4. **Cloudflare entfaellt** (11.09.2026): `binaergewitter.de` wird nicht mehr vom
   Cluster bedient. Kein `cloudflare-api-key` im Cluster.
5. `horads.de` und `steinba.ch` verwenden mangels Provider-Zugriff HTTP-01. Der
   Solver ist explizit auf diese beiden Zonen begrenzt; jeder betroffene Ingress setzt
   `acme.cert-manager.io/http01-edit-in-place: "true"`.

Eine CNAME-Delegation gilt pro angefordertem DNS-Namen. Vor der Solver-Zuordnung
jeder Zone wird die oeffentliche NS-Delegation unmittelbar vor dem Rollout erneut
geprueft.

Zu inventarisierende Zonen:

```text
jit.services
savar.de
jit-creatives.de
jitcreatives.de
jitmail.de
gemeinsam-fuer-halbe.de
jugendbeauftragter-halbe.de
porga.de
horads.de
imcor.de
jonaks.com
jit.cloud
naturkindergarten-moehringen.de
steinba.ch
daec-berlin.de
```

`porga.de` ist neu (Router `expense.porga.de`); die Zone liegt auf dns01 und ist
`inline-signing` ohne DS — RFC2136-Faehigkeit vor dem Staging pruefen.

### Sonderfall: steinba.ch-Mailzertifikat

Heute: Traefik holt das Zertifikat fuer `imap/pop/smtp.steinba.ch` per HTTP-01
(Router mit toter Senke), ein Cron auf `.15` verteilt es an mail05.

Zielkette:

1. Ein eigener Ingress (oder `Certificate` mit HTTP-01-Solver) fuer die drei Namen
   im Cluster, Solver auf `steinba.ch` begrenzt. Kein ausgelieferter Inhalt auf 443.
2. Die Verteilung an mail05 zieht vom `.15`-Cron auf einen Mechanismus, der das
   Kubernetes-Secret liest — z. B. derselbe Skriptablauf auf `cfgmgmt01` mit
   `kubectl get secret`, oder ein CronJob im Cluster mit SSH-Key auf mail05.
   Das Skript `/usr/local/sbin/steinbach-cert-deploy.sh` (SNI-Map-Erzeugung,
   Hash-Vergleich) wird dafuer uebernommen, nur die Quelle aendert sich.
3. Einmal vollstaendig durchspielen (Staging-Zertifikat an mail05 → `openssl s_client
   -starttls imap` pruefen → zurueck auf Produktion), bevor Port 80 umgestellt wird.

Frist: Das aktuelle Zertifikat laeuft am 04.12.2026 ab; Traefik erneuert ab etwa
Anfang November. Wird Port 80 vorher umgestellt, muss die Zielkette schon stehen.

### Zertifikate ohne Redirect-Loop ausstellen

Alle bisher HTTP-only betriebenen Ingresses erhalten Issuer und `spec.tls`.
Waehrend der reinen Zertifikatsausstellung bleiben gesetzt:

```yaml
nginx.org/ssl-redirect: "false"
nginx.org/redirect-to-https: "false"
```

Nach erfolgreicher TLS-Abnahme, noch vor dem WAN-Cutover, wird
`nginx.org/redirect-to-https: "true"` aktiviert (entscheidet anhand von
`X-Forwarded-Proto`; Traefik setzt `https`, also kein Loop). `nginx.org/ssl-redirect`
bleibt nur bis zum 443-Cutover `false` und wird aktiviert, bevor Port 80 auf `.246`
zeigt.

Vor dem NAT-Wechsel muessen beide Pfade funktionieren:

```text
externes HTTPS ueber .15 -> .246:80: kein Redirect-Loop
direktes HTTP zu .246:80: Redirect auf https://<host>/
```

Zuerst `letsencrypt-staging`; Produktion erst, wenn TXT-Create, oeffentliche
Sichtbarkeit und Cleanup fuer jede Solver-Klasse funktionieren.

### Solvermatrix

| Ingress | DNS-Namen | Solver | Delegation | Status |
|---|---|---|---|---|
| `wordpress-1/wordpress` | `jugendbeauftragter-halbe.de`, `www.` | RFC2136 | direkt | TXT E2E verifiziert; Alt-Certificate am 11.09. entfernt |
| `wordpress-2/wordpress` | `gemeinsam-fuer-halbe.de`, `www.` | RFC2136 | direkt | TXT E2E verifiziert; Alt-Certificate am 11.09. entfernt |
| `kimai/kimai` | `kimai.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `paperless-ngx/paperless-paperless-ngx` | `paperless.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `mailman/mailman` | `lists.jitmail.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `gatus-public/gatus-public` | `status.jit-creatives.de` | RFC2136 | direkt | neu aufgenommen, Staging ausstehend |
| `expense-tracker/expense-tracker` | `expense.porga.de` | RFC2136 | direkt | neu aufgenommen, Zone pruefen |
| `roundcube/roundcube-jitmail` | `roundcube.savar.de`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de`, `webmail.daec-berlin.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `roundcube/roundcube-jitmail` | `mail.steinba.ch` | HTTP-01 in-place | Port 80 | Staging ausstehend |
| (neu) steinba.ch-Mail | `imap.steinba.ch`, `pop.steinba.ch`, `smtp.steinba.ch` | HTTP-01 | Port 80 | neu, Zielkette offen |
| `collabora/collabora-office-savar` | `office.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/mgmt02` | vier Namen unter `jit-creatives.de`/`jitcreatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/umdiehand` | zwei Namen unter `jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/horads` | `stream.horads.de` | HTTP-01 in-place | Port 80 | Staging ausstehend |
| `legacy-proxy/spam` | `spam.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/imcor` | sechs Namen unter `imcor.de`/`jonaks.com` | RFC2136 Follow | CNAMEs vorhanden | Delegation E2E verifiziert; drei Namen ohne A-Record (Hostmatrix) |
| `legacy-proxy/auth` | `auth.savar.de`, `auth2.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/s3` | `s3.savar.de`, `s3.jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/jitcloud` | `cloud.savar.de`, `jit.cloud`, `cloud.daec-berlin.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/jitcloud` | `cloud.naturkindergarten-moehringen.de` | RFC2136 Follow | CNAME fehlt | blockiert |
| `legacy-proxy/jitcloud` | `cloud.steinba.ch` | HTTP-01 in-place | Port 80 | Staging ausstehend |
| `legacy-proxy/cloud-dev` | `cloud-dev.savar.de` | RFC2136 | direkt | bleibt; Backend tot, Staging ausstehend |
| `phpmyadmin/phpmyadmin` | `dbadmin.jit.services` | ClouDNS | direkt | bestehender Produktionspfad |
| `phpmyadmin/phpmyadmin` | `phpmyadmin.savar.de`, `phpmyadmin.jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |

Entfallen am 11.09.2026: `binaergewitter/*` (Cloudflare), `podcast.savar.de`,
`legacy-proxy/gitlab`, `legacy-proxy/gitlab-registry`, `legacy-proxy/aios`.

Am 30.07.2026 wurden in allen neun RFC2136-Zonen temporaere TXT-Records erstellt,
ueber `1.1.1.1` verifiziert und wieder entfernt. Bei `jitcreatives.de`,
`jugendbeauftragter-halbe.de` und `jit.cloud` hingen die inline-signierten Views; der
dokumentierte Recovery-Ablauf war `rndc freeze`, `named-checkzone`, die jeweilige
`.db.jnl` reversibel nach `.jnl.stale-20260730T124500Z` verschieben, `rndc thaw`.
Danach war der E2E-Test fuer alle neun Zonen erfolgreich.

Die delegierten Challenges verwenden eindeutige Ziele unter `acme.jit-creatives.de`.
Ein permanenter TXT-Record am Knoten `acme.jit-creatives.de` verhindert, dass das
vorhandene `*.jit-creatives.de`-CNAME auf `halbe.jit-creatives.de` fuer diese tieferen
Namen synthetisiert wird.

Bei den externen Providern sind exakt diese CNAMEs anzulegen (United Domains ohne
DNS-API, deshalb einmalig manuell):

| Provider-Record | Ziel | Stand |
|---|---|---|
| `_acme-challenge.imcor.de` | `_acme-challenge.imcor.de.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.www.imcor.de` | `_acme-challenge.www.imcor.de.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.db.imcor.de` | `_acme-challenge.db.imcor.de.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.config.imcor.de` | `_acme-challenge.config.imcor.de.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.jonaks.com` | `_acme-challenge.jonaks.com.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.www.jonaks.com` | `_acme-challenge.www.jonaks.com.acme.jit-creatives.de.` | vorhanden |
| `_acme-challenge.cloud.naturkindergarten-moehringen.de` | `_acme-challenge.cloud.naturkindergarten-moehringen.de.acme.jit-creatives.de.` | **fehlt** |

Nach jeder Provider-Aenderung CNAME und Ziel ueber einen oeffentlichen Resolver
pruefen, bevor das zugehoerige Ingress-TLS aktiviert wird. Ein blosses
`Certificate Ready=True` reicht nicht: zu jeder Ausstellung wird die erzeugte
`Challenge` kontrolliert.

## Phase 3: `.246` pinnen und echte Client-IP erhalten

Hartes Gate — nicht wegen CrowdSec, sondern wegen der IP-basierten Schutz- und
Drosselmechanismen der Anwendungen (Nextcloud-Brute-Force-Schutz, Roundcube,
`auth.savar.de`). Mit SNAT saehen diese alle Clients als dieselbe Node-IP.

Der nginx-Service besitzt live `.246`, die IP ist aber nicht deklarativ gepinnt
(Pool `.246-.249`). Sie wird am Service fixiert. Die globale `default-l2`-Policy wird
durch explizite Policies fuer die benoetigten LoadBalancer ersetzt; Mailman `.247`
muss weiter angekuendigt werden. Vorher alle LoadBalancer-IPs und L2-Leases
inventarisieren.

`externalTrafficPolicy: Local` ist keine einfache Loesung: Cilium-L2 kann die VIP auf
einem Node ohne lokalen nginx-Pod announcen — genau das verursachte bereits einen
Ausfall (22.07.2026).

Der Cluster verwendet Cilium `1.16.5` mit SNAT/VXLAN. DSR/Hybrid ist eine clusterweite
CNI- und ggf. Tunnelmigration mit eigenem Wartungs- und Rollbackplan. Sie sollte mit
dem anstehenden Update auf `1.20.0` zusammen geplant werden.

Zu vergleichen:

1. Cilium DSR/Hybrid mit `externalTrafficPolicy: Cluster` und erhaltener Source-IP
   (Kompatibilitaet, MTU, Geneve/native Routing, Upgrade-Pfad, Rollback).
2. Ein endpoint-aware L2-LoadBalancer, der `externalTrafficPolicy: Local` zuverlaessig
   unterstuetzt.

Erst nach der Entscheidung dient `.249` als Canary-IP, mit temporaerem, dokumentiertem
UDM-Portforward fuer echte externe Tests.

Abnahmekriterien des Canary:

```text
echte externe IPv4 im nginx-Log
keine Uebernahme eines gespooften X-Forwarded-For
funktionierender Wechsel des L2-Lease-Holders
kein Ausfall bei nginx-Pod- oder Node-Neustart
korrekter Rueckweg ohne asymmetrisches Routing
```

Nach dem Direkt-Cutover darf nginx nicht weiter beliebige XFF-Werte aus
`192.168.2.0/24` akzeptieren (heute `set-real-ip-from: 192.168.2.0/24`).

## Phase 4: CrowdSec-Enforcement (optional)

Seit 11.09.2026 kein Gate. Die Cluster-CrowdSec-Installation ist Detection-only; der
verbliebene nc05-Bouncer auf `.15` faellt mit dem Cutover weg. Das ist bewusst
akzeptiert.

Moegliche spaetere Varianten: HTTP-Bouncer im Ingress-Pfad, dynamisches
Cilium-/Firewall-Enforcement oder Enforcement auf der UDM. Voraussetzung ist in jedem
Fall Phase 3 (echte Client-IP). Ein kontrollierter Test sperrt eine Test-IP und gibt
sie wieder frei, ohne Node-, Pod- oder Proxy-IPs zu treffen.

## Phase 5: Funktionstest direkt gegen `.246`

Jeder Host wird vor dem WAN-Cutover lokal mit festem SNI getestet:

```bash
HOST=kimai.savar.de
curl --resolve "$HOST:443:192.168.2.246" "https://$HOST/"
openssl s_client -connect 192.168.2.246:443 -servername "$HOST" </dev/null
```

Pro SNI: Hostname, Chain, Ablaufdatum, SAN, erwartetes Secret. Betroffene
ArgoCD-Applications `Synced/Healthy`; jeder Ingress hat nach dem letzten Rollout ein
aktuelles `AddedOrUpdated`-Event.

Zusaetzlich pruefen:

- OIDC-Discovery und echter Login ueber `auth.savar.de`.
- Nextcloud Login, WebDAV, Upload/Download.
- Mailman Web, LMTP, REST, Listenmail und Moderation.
- Roundcube Login, Identitaeten, Kontakte, IMAP und SMTP.
- WordPress Frontend, `/wp-admin` und Redirects.
- Collabora: Dokument oeffnen, bearbeiten, speichern.
- S3 Upload/Download, Icecast-Langzeitstream.
- Alle verbleibenden `legacy-proxy`-Hosts.
- steinba.ch-Mailzertifikat auf mail05 (`openssl s_client -starttls imap`).
- Gatus sowie nginx-, cert-manager- und Anwendungslogs.

Die Hostmatrix oben wird dafuer um Testpfad, Erwartung, Owner und Sign-off ergaenzt.

## Phase 6: UDM-Cutover

Vorher:

1. UniFi-Konfiguration exportieren.
2. Regeln fuer TCP 80, 443, 2525 und 8080 mit Zieladressen dokumentieren
   (2525 war am 11.09. von aussen bereits geschlossen; 8080 bleibt offen).
3. Rollback auf `.15` vorbereiten.
4. Langzeitverbindungen und geplante Wartungen pruefen.

UDM-Ist-Stand 11.09.2026 (NAT-Regeln auf WAN `eth7`, identisch gespiegelt auf `ppp0`):

| WAN-Port | Ziel | Bewertung |
|---|---|---|
| 80, 443 | `192.168.2.15` | Gegenstand dieses Cutovers |
| 8080 | `192.168.2.240:8080` (Icecast) | bleibt (Entscheidung 11.09.) |
| 2525 | — | existiert nicht mehr |
| 5050 | `192.168.2.15:5050` | **veraltet**, Registry laeuft ueber edge01 → entfernen |
| 21, 30000–30010 | `192.168.2.15` | **veraltet**, proftpd-Container seit Monaten gestoppt → entfernen |
| 22617 | `192.168.2.17:22` | **veraltet**, GitLab seit 26.08. unter `88.198.107.9:22617` → entfernen |
| 2299 | `192.168.2.66:22` | **veraltet**, Auphonic-SFTP seit 28.08. unter `88.198.107.9:2299` → entfernen |
| 2233 | `192.168.2.29:22` | **veraltet**, kniff01 seit 11.09. unter `88.198.107.9:2233` → entfernen |
| 2001 | `192.168.2.29:8000` | **veraltet**, kniff01 migriert → entfernen |

Nicht Teil dieses Plans, zur Vollstaendigkeit: 22→`.21`, 2211→`.30:22`, 2255→`.170:22`,
2277→`.23:22`, 2288→`.10:22`, 25→`.209`, 110/143/465/587/993/995/4190→`.34`,
11333/6379/26379→`.230`, 3306→`.32`, 5000/5222/5269/5281→`.14`, 53/853→`.236`,
5353→`.10:53`, 8000→`.238`, 8089→`192.168.23.18`, 25565→`.241`.

Cutover-Reihenfolge:

1. XFP-basiertes `redirect-to-https` ist auf `.246` aktiviert und hinter Traefik wie
   auch direkt getestet.
2. TCP 80 bleibt zunaechst auf `.15` (bestehender HTTPS-Redirect, steinba.ch-HTTP-01).
3. TCP 443 von `.15` auf `.246` umstellen.
4. Vollstaendige externe TLS- und Anwendungs-Abnahme.
5. Waehrend TCP 80 noch auf Traefik zeigt, `nginx.org/ssl-redirect: "true"` per GitOps
   aktivieren; direkt gegen `.246:80` pruefen, dass auch ein gespooftes
   `X-Forwarded-Proto: https` auf HTTPS umgeleitet wird.
6. Erst danach TCP 80 von `.15` auf `.246` umstellen. Die HTTP-01-Solver fuer
   `horads.de`/`steinba.ch` direkt danach per Staging-Probe verifizieren.
7. `.15` eingeschaltet und unveraendert als Rollback bereithalten.

Falls die UDM beide Regeln nur gemeinsam aendern kann: vorher WAN-TCP-80 temporaer
sperren, atomar umstellen, `ssl-redirect` aktivieren und inklusive XFP-Spoof-Test
verifizieren, dann Port 80 wieder freigeben. Ein Zustand mit erreichbarer `.246` auf
Port 80 und deaktiviertem `ssl-redirect` ist nicht zulaessig.

## Phase 7: Postfix und Legacy-Daten beenden

### Postfix

Stand 11.09.2026: Die Voraussetzungen sind erfuellt.

- mx02 liefert alle Listenadressen empfaengergenau direkt an
  `lmtp:[192.168.2.247]:8024` (`/etc/postfix/transport`).
- WAN-Port 2525 ist von aussen geschlossen.
- Postfix auf `.15` hat seit dem Neustart am 10.08.2026 keine Verbindung und eine
  leere Queue (Beobachtungsfenster 10.08.–01.09. formal geschlossen).

Ausfuehrung:

1. ~~UDM-Regel 2525~~ — existiert nicht mehr (NAT-Ist-Stand 11.09.).
2. Statt einer synthetischen Testmail: Produktivzustellungen mx02 → `.247` im Log belegt
   (zuletzt 02.09.), keine einzige Zustellung an `.15`.
3. ~~Postfix stoppen~~ — erledigt 11.09.2026. Beobachtung bis **18.09.2026**.
4. `192.168.2.15/32` aus `mynetworks` auf mx02 entfernen (Ansible
   `group_vars/mx_gateways.yml`, `mx_gateway_trusted_clients`), ebenso aus
   `sign_networks` der rspamd-Konfiguration auf spam01/02.

Port 2525 wird niemals direkt auf LMTP weitergeleitet.

### Legacy-Datenbanken

Stand 11.09.2026: **Schritte 1–4 erledigt.**

| Datenbank | Objekt (`backups/docker15-legacy/20260911/`) | gz | Tabellen / Zeilen | Test-Restore |
|---|---|---:|---|---|
| Mailman (postgres, `pg_dumpall`) | `mailman.sql.gz.age` | 11,9 MB | 61 / 45.097 | identisch |
| XWiki (mysql 5.7, `db`) | `xwiki.sql.gz.age` | 517 B | 0 / 0 (leer) | identisch |
| WordPress gemeinsam-fuer-halbe (`wordpress-db1`) | `wordpress-gemeinsamfuerhalbe.sql.gz.age` | 1,39 MB | 28 / 1.571 | identisch |
| WordPress jugendbeauftragter (`wordpress-db2`) | `wordpress-jugendbeauftragter.sql.gz.age` | 121 KB | 12 / 781 | identisch |

- Ablage: Garage-S3 Potsdam (`192.168.23.21:3900`, Region `garage-potsdam`), Bucket
  `backups`, eigener Key `docker15-legacy-dumps` (RW). Die Zugangsdatei auf `.15` wurde
  nach dem Upload geloescht.
- Verschluesselung: `age` auf den SOPS-Recipient
  `age17x04ga87qyu9lzcuja9k83z90veew9cez7jusul4y5xyr09xaejs9rq755`. Ver- und Entschluesseln
  nur auf dem Laptop (`~/.config/sops/age/keys.txt`); unverschluesselt lag nichts auf Platte.
- Integritaet: `MANIFEST.tsv` (sha256 von gz-Klartext und age-Datei) und
  `source-rowcounts.tar.gz` (exakte Zeilenzahlen je Tabelle an der Quelle).
- Test-Restore: aus Garage gelesen, entschluesselt, sha256 gegen Manifest, eingespielt in
  isolierte Wegwerf-Container (`--network none`, gleiche Images), Zeilenzahlen je Tabelle
  identisch, 0 Importfehler, Container entfernt.
- Restore:
  `rclone cat garage:backups/docker15-legacy/20260911/<name>.sql.gz.age | age -d -i ~/.config/sops/age/keys.txt | gunzip | <psql|mysql|mariadb>`
- **Aufbewahrung 1 Jahr, Loeschdatum 11.09.2027** (Entscheidung 11.09.2026).
- Schritt 6 erledigt 11.09.: alle vier Container gestoppt, `restart=no`, Daten und Compose-Dateien unveraendert.

Fuer jede der vier Datenbanken:

1. Konsistenten Dump und Dateisystem-Backup erstellen.
2. Checksummen, Verschluesselung und externen Aufbewahrungsort dokumentieren.
3. Test-Restore in eine isolierte Instanz.
4. Aktive Verbindungen und Schreibzugriffe ausschliessen.
5. Aufbewahrungs- und Loeschdatum dokumentieren.
6. Container stoppen, Daten und Compose-Dateien noch nicht loeschen.

Die Mailman-Alt-Datenbank bleibt bis zum Ende der Mailman-Rollback-Frist erhalten.

## Phase 8: Soft-Off und Abschaltung

1. Direkten `.246`-Betrieb mindestens sieben Tage beobachten.
2. Traefik auf `.15` stoppen; VM bleibt eingeschaltet.
3. steinba.ch-Cron auf `.15` deaktivieren (Zielkette muss bereits geliefert haben).
4. Postfix, nc05-Bouncer und Legacy-Datenbanken stoppen.
5. Weitere 72 Stunden beobachten.
6. VM-Snapshot sowie externe Konfigurations- und Datenbackups erstellen.
7. VM 107 auf `pve` herunterfahren, `onboot` deaktivieren.
8. Nach 14 bis 30 Tagen Karenz endgueltig entfernen.
9. Danach aufraeumen: Bouncer-Registrierungen (nc05-LAPI; GitLab-LAPI jetzt auf
   `10.10.10.5`), `mynetworks`/`sign_networks`, DNS-Namen `docker.jit.land`,
   Ansible-Inventar, Potsdam-DR-Edge-`host_vars`.
10. **Cloudflare-API-Key:** Der globale Key aus der `.15`-Compose wird auch von
    `edge01` (victorianix, Resolver `lecf`) genutzt. Rotation deshalb nicht mit der
    `.15`-Abschaltung koppeln, sondern als eigenen Schritt: zonenbeschraenkten Token
    fuer edge01 anlegen, dann den globalen Key widerrufen.

## Rollback

Vor dem Web-Rollback wird zuerst entweder die Traefik-Konfiguration auf HTTPS zu
`.246:443` umgestellt und verifiziert oder die Redirect-Aktivierung per Git revertiert
und von ArgoCD ausgerollt. Erst danach werden die UDM-Regeln fuer TCP 80/443 auf `.15`
zurueckgesetzt. Die umgekehrte Reihenfolge erzeugt sofort den Redirect-Loop.

Falls fuer den Source-IP-Erhalt Cilium-, Tunnel- oder L2-Komponenten geaendert
wurden, gilt deren separat getesteter Plattform-Rollback als Voraussetzung. Ein
UDM-Rollback allein repariert keine fehlerhafte Cluster-Netzwerkebene.

Die am 11.09.2026 entfernten Router lassen sich aus
`dynamic_conf.yml.bak-20260911-cleanup` wiederherstellen; oeffentlich zeigen die
betroffenen Namen ohnehin nicht mehr auf `.15`.

Mail-Rollback ist getrennt:

```text
Postfix auf .15 starten, transport_mailman ist unveraendert
192.168.2.15/32 in mynetworks auf mx02 wiederherstellen (falls schon entfernt)
Queue und Zustellung zu 192.168.2.247:8024 pruefen
```

`.15` wird bis zum Ende der Karenz weder geloescht noch neu aufgesetzt.

## Review-Fragen

Stand 11.09.2026:

| # | Frage | Stand |
|---|---|---|
| 1 | Source-IP per Cilium DSR/Hybrid oder endpoint-aware L2-LB? Zusammen mit Cilium `1.20.0`? | **offen** |
| 2 | Welche Zonen sind auf dns01 autoritativ und fuer RFC2136 freigegeben? | beantwortet (E2E 30.07.), `porga.de` neu zu pruefen |
| 3 | Cloudflare per API-Token oder CNAME-Delegation? | entfallen (keine Cloudflare-Zone mehr im Cluster) |
| 4 | Welche Enforcement-Variante ersetzt die CrowdSec-Bouncer? | entschieden: kein Gate, spaeter optional |
| 5 | `home.savar.de`, `tools.kniff.eu`, `netbox.kniff.eu`? | entschieden: kniff umgezogen; `home.savar.de`-Dashboard entfaellt (11.09.) |
| 6 | Aufbewahrung Mailman-Altbestand und Legacy-DB-Backups? | entschieden: 1 Jahr, Loeschdatum 11.09.2027 |
| 7 | DNS-01 fuer `gemeinsam-fuer-halbe.de` vor dem 10.09.? | entfallen (Alt-Certificate geloescht, Traefik liefert bis zum Cutover) |
| 8 | Wie wird das steinba.ch-Mailzertifikat kuenftig bezogen und verteilt? | **neu, offen** |
| 9 | `cloud-dev.savar.de` weiterbetreiben oder abkuendigen? | entschieden: bleibt (11.09.) |
| 10 | `db.imcor.de`, `config.imcor.de`, `www.jonaks.com` (kein A-Record) im Zertifikat behalten? | entschieden: behalten, A-Records angelegt |
| 11 | Soll WAN-Port 8080 (Icecast) offen bleiben? | entschieden: bleibt offen (11.09.) |
| 12 | Potsdam-DR-Edge aktualisieren oder aufgeben? | entschieden: aktualisieren; Rollout blockiert (IP-Konflikt `.20`) |
