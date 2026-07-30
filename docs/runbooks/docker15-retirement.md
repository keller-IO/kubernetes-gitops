# Abschaltplan fuer docker15 (192.168.2.15)

Status: Phase 1 inventarisiert; Phase 2 vorbereitet, noch nicht ausgerollt.

Planstand: 2026-07-30.

## Zielbild

Der regulaere Produktionspfad soll ohne vorgeschalteten Traefik direkt in den
Cluster fuehren:

```text
Internet -> UDM 192.168.2.94 -> nginx-inc 192.168.2.246
         -> Cluster-Workloads
         -> legacy-proxy -> externe Backends im LAN
```

`192.168.23.20` ist kein Bestandteil dieses Produktionspfads. Der Host bleibt
ausschliesslich als Disaster-Recovery-Edge vorgesehen, falls der Internet-Traffic
ueber Potsdam geroutet werden muss.

Der Plan trennt drei Meilensteine:

1. Direkten Web-Traffic auf `192.168.2.246` vorbereiten und umstellen.
2. Nicht-Web-Aufgaben von `192.168.2.15` entfernen.
3. Die VM nach Beobachtungs- und Rollback-Frist abschalten.

## Aktueller Bestand auf docker15

Die Live-Inventur am 30.07.2026 ergab:

| Aufgabe | Aktueller Zustand | Abschaltbedingung |
|---|---|---|
| Traefik | TCP 80/443, TLS und Routing fuer alle Legacy-Domains | Alle Hosts, Zertifikate und Sonderregeln auf nginx-inc verifiziert |
| Postfix | TCP 25, acht Transport-Domains zu Cluster-LMTP | Kein produktiver Eingang mehr ueber Router-Port 2525, Queue dauerhaft leer |
| CrowdSec | Zwei aktive Host-Firewall-Bouncer fuer GitLab- und nc05-LAPI | Gleichwertiges Enforcement im direkten `.246`-Pfad nachgewiesen |
| Mailman-Postgres | Alt-/Rollback-Datenbank laeuft weiter | Konsistentes Archiv und Ende der Mailman-Rollback-Frist |
| WordPress-MariaDBs | Zwei Alt-Datenbanken laufen, Webcontainer sind gestoppt | Dumps, keine aktiven Clients, definierte Aufbewahrung |
| XWiki-MySQL | Datenbank laeuft, XWiki ist gestoppt | Dump, keine aktiven Clients, definierte Aufbewahrung |

Die UDM-Portforwards sind nicht in Ansible oder Git versioniert. Vor dem Cutover
muss deshalb ein UniFi-Export erstellt und der Ist-Zustand der Regeln fuer 80,
443 und 2525 in diesem Runbook nachgetragen werden.

## Harte Freigabe-Gates

Kein WAN-Cutover, solange eines dieser Gates offen ist:

- [ ] nginx-inc besitzt deklarativ und stabil `192.168.2.246`.
- [ ] Jeder produktive Traefik-Host existiert als akzeptierter Cluster-Ingress
      oder ist ausdruecklich zur Abschaltung freigegeben.
- [ ] Jedes SNI hat auf `.246:443` ein gueltiges, `Ready=True`-Zertifikat.
- [ ] Eine versionierte Host-zu-DNS01-Solver-Matrix deckt jedes Zertifikat ab;
      der tatsaechlich erzeugte ACME-Challenge-Typ und Solver stimmen damit
      ueberein. Der Catch-all-HTTP01-Solver ist eingeschraenkt oder entfernt.
- [ ] Kein Ingress hat ein `Rejected`-Event.
- [ ] Alle manuell verwalteten EndpointSlices existieren mit korrekter Adresse,
      Port und Ready-Condition.
- [ ] Die echte externe Client-IP bleibt ohne Vertrauen in beliebige Client-XFF
      erhalten; ein Spoof-Test ist negativ.
- [ ] CrowdSec- oder gleichwertiges Edge-Enforcement ist im neuen Pfad aktiv
      und mit einem kontrollierten Blocktest verifiziert.
- [ ] Die vollstaendige Anwendungs-Abnahmematrix ist erfolgreich.
- [ ] Fuer jeden Host sind IPv4 und IPv6 inventarisiert. Entweder existiert kein
      produktives AAAA oder ein separat getesteter IPv6-Pfad ist dokumentiert.
- [ ] UDM-Rollback und Git-Rollback sind vorbereitet und widersprechen sich
      nicht bei HTTPS-Redirects.

## Phase 1: Live-Router vollstaendig abbilden

`/opt/containers/traefik/data/dynamic_conf.yml` und die Docker-Labels des
Traefik-Containers sind die Ausgangsliste. Fuer jeden Router werden Host, Pfad,
Backend-Protokoll, WebSocket, Rewrite, Body-Limit, Timeout, Header, Auth und CORS
erfasst.

Die Live-Inventur hat drei noch nicht im Cluster abgebildete Hosts gefunden:

| Host | Live-Ziel | Entscheidung |
|---|---|---|
| `tools.kniff.eu` | `192.168.2.29:80` | legacy-proxy-Ingress anlegen oder Host abkuendigen |
| `netbox.kniff.eu` | `192.168.2.29:8000` | legacy-proxy-Ingress anlegen oder Host abkuendigen |
| `home.savar.de` | Traefik-Dashboard auf `.15` | Dashboard entfernen oder geschuetzten Ersatz definieren |

Die vorhandenen `legacy-proxy`- und Binaergewitter-Services bleiben selectorlos.
Ihre EndpointSlices werden von ArgoCD ausgeschlossen und muessen vor dem Cutover
live gegen die Manifeste abgeglichen werden.

## Phase 2: DNS-01 und Cluster-Zertifikate

TLS terminiert nach dem Cutover an nginx-inc. Zertifikate werden neu durch
cert-manager ausgestellt; Traefik-ACME-Dateien werden nicht in Git oder in
Kubernetes importiert.

### Solver-Strategie

1. `jit.services` bleibt beim vorhandenen ClouDNS-DNS-01-Webhook.
2. Auf `dns01.jit-creatives.de` autoritative Zonen werden ueber den vorhandenen
   RFC2136-Solver und das SOPS-Secret `rfc2136-tsig` bedient.
3. `imcor.de`, `jonaks.com` und `naturkindergarten-moehringen.de` delegieren
   `_acme-challenge` per CNAME auf die von `dns01` verwalteten Zielnamen. Der
   Solver verwendet dafuer `cnameStrategy: Follow`.
4. `binaergewitter.de` verwendet fuer den ersten Cutover den vorhandenen globalen
   Cloudflare-Key aus der Traefik-Compose-Umgebung. Eine API-Pruefung bestaetigte,
   dass das Konto nur diese eine Zone verwaltet. Das Ziel bleibt ein auf die Zone
   beschraenkter API-Token mit `Zone:Read` und `DNS:Edit`.
5. `horads.de` und `steinba.ch` verwenden mangels Provider-Zugriff HTTP-01.
   Der Solver ist explizit auf diese beiden Zonen begrenzt. Weil nginx-inc einen
   zweiten Ingress mit demselben Host ablehnt, setzt jeder betroffene Ingress
   `acme.cert-manager.io/http01-edit-in-place: "true"`.

Eine CNAME-Delegation gilt pro angefordertem DNS-Namen. Fuer Zertifikate mit
mehreren SANs braucht jeder Name einen eigenen `_acme-challenge.<name>`-CNAME;
alternativ werden bewusst gruppierte Wildcard-Zertifikate mit dokumentierter
Zone und Nutzung eingesetzt.

Vor der Solver-Zuordnung jeder Zone muss die oeffentliche NS-Delegation geprueft
werden. Eine vorhandene Zone auf `dns01` beweist nicht, dass sie im Internet
autoritative Antworten liefert. `gemeinsam-fuer-halbe.de` war in einer frueheren
Pruefung bei Cloudflare; die Registry- und Autoritaetspruefung am 30.07.2026
lieferte dagegen `ns.jitcreatives.de` und `ns3.jitcreatives.de`. Diese Delegation
muss unmittelbar vor dem Rollout erneut kontrolliert werden.

Zu inventarisierende Zonen:

```text
jit.services
savar.de
jit-creatives.de
jitcreatives.de
jitmail.de
binaergewitter.de
gemeinsam-fuer-halbe.de
jugendbeauftragter-halbe.de
horads.de
imcor.de
jonaks.com
aios.tools
jit.cloud
naturkindergarten-moehringen.de
steinba.ch
daec-berlin.de
kniff.eu
```

### Zertifikate ohne Redirect-Loop ausstellen

Alle bisher HTTP-only betriebenen Ingresses erhalten Issuer und `spec.tls`.
Waehrend der reinen Zertifikatsausstellung bleiben diese Annotationen gesetzt:

```yaml
nginx.org/ssl-redirect: "false"
nginx.org/redirect-to-https: "false"
```

Nach erfolgreicher TLS-Abnahme, aber noch vor dem WAN-Cutover, wird
`nginx.org/redirect-to-https: "true"` aktiviert. Diese Variante entscheidet
anhand von `X-Forwarded-Proto`: Traefik setzt fuer bereits externes HTTPS den
Wert `https`, sodass kein Loop entsteht; eine direkte HTTP-Anfrage an `.246`
erhaelt dagegen bereits den Redirect. Dieser Schutz ist allein noch nicht
spoof-resistent. `nginx.org/ssl-redirect` bleibt deshalb nur bis zum vollzogenen
443-Cutover `false` und wird aktiviert, bevor Port 80 auf `.246` zeigt.

Vor dem NAT-Wechsel muessen daher beide Pfade erfolgreich sein:

```text
externes HTTPS ueber .15 -> .246:80: kein Redirect-Loop
direktes HTTP zu .246:80: Redirect auf https://<host>/
```

Zuerst wird mit einem `letsencrypt-staging`-Issuer getestet. Produktion folgt
erst, wenn TXT-Create, oeffentliche Sichtbarkeit und Cleanup fuer jede
Solver-Klasse funktionieren.

Solvermatrix fuer die bisher HTTP-only oder nur teilweise TLS-abgedeckten
Ingresses:

| Ingress | DNS-Namen | Solver | Delegation | Status |
|---|---|---|---|---|
| `wordpress-1/wordpress` | `jugendbeauftragter-halbe.de`, `www.jugendbeauftragter-halbe.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `wordpress-2/wordpress` | `gemeinsam-fuer-halbe.de`, `www.gemeinsam-fuer-halbe.de` | RFC2136 | direkt | TXT E2E verifiziert; NS vor Rollout pruefen |
| `kimai/kimai` | `kimai.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `paperless-ngx/paperless-paperless-ngx` | `paperless.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `mailman/mailman` | `lists.jitmail.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `roundcube/roundcube-jitmail` | `roundcube.savar.de`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de`, `webmail.daec-berlin.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `roundcube/roundcube-jitmail` | `mail.steinba.ch` | HTTP-01 in-place | direkt ueber Port 80 | Staging ausstehend |
| `collabora/collabora-office-savar` | `office.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `binaergewitter/binaergewitter` | `comments`, `search`, `download`, `pad`, `plan` unter `binaergewitter.de` | Cloudflare | direkt | Staging ausstehend |
| `binaergewitter/binaergewitter` | `podcast.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `binaergewitter/binaergewitter-etherpad` | `etherpad.binaergewitter.de` | Cloudflare | direkt | Staging ausstehend |
| `legacy-proxy/mgmt02` | vier Namen unter `jit-creatives.de`/`jitcreatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/umdiehand` | zwei Namen unter `jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/horads` | `stream.horads.de` | HTTP-01 in-place | direkt ueber Port 80 | Staging ausstehend |
| `legacy-proxy/gitlab` | `gitlab.jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/gitlab-registry` | `registry.jit-creatives.de`, `registry.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/spam` | `spam.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/imcor` | sechs Namen unter `imcor.de`/`jonaks.com` | RFC2136 Follow | CNAMEs fehlen | blockiert |
| `legacy-proxy/aios` | `www.aios.tools`, `test.aios.tools` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/auth` | `auth.savar.de`, `auth2.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/s3` | `s3.savar.de`, `s3.jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/jitcloud` | `cloud.savar.de`, `jit.cloud`, `cloud.daec-berlin.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `legacy-proxy/jitcloud` | `cloud.naturkindergarten-moehringen.de` | RFC2136 Follow | CNAME fehlt | blockiert |
| `legacy-proxy/jitcloud` | `cloud.steinba.ch` | HTTP-01 in-place | direkt ueber Port 80 | Staging ausstehend |
| `legacy-proxy/cloud-dev` | `cloud-dev.savar.de` | RFC2136 | direkt | TXT E2E verifiziert |
| `phpmyadmin/phpmyadmin` | `dbadmin.jit.services` | ClouDNS | direkt | bestehender Produktionspfad |
| `phpmyadmin/phpmyadmin` | `phpmyadmin.savar.de`, `phpmyadmin.jit-creatives.de` | RFC2136 | direkt | TXT E2E verifiziert |

Am 30.07.2026 wurden in allen neun RFC2136-Zonen temporaere TXT-Records
erstellt, ueber `1.1.1.1` verifiziert und wieder entfernt. Bei
`jitcreatives.de`, `jugendbeauftragter-halbe.de` und `jit.cloud` nahmen die
unsigned Zonen Updates an, waehrend die inline-signierten Views festhingen.
Der dokumentierte Recovery-Ablauf war: `rndc freeze`, `named-checkzone`, die
jeweilige `.db.jnl` reversibel nach `.jnl.stale-20260730T124500Z` verschieben,
danach `rndc thaw`. Ein erneuter E2E-Test war fuer alle neun Zonen erfolgreich.

Die delegierten Challenges verwenden eindeutige Ziele unter
`acme.jit-creatives.de`. Ein permanenter TXT-Record am Knoten
`acme.jit-creatives.de` verhindert, dass das vorhandene
`*.jit-creatives.de`-CNAME auf `halbe.jit-creatives.de` fuer diese tieferen
Namen synthetisiert wird. Ein temporaeres RFC2136-Update unter diesem Knoten war
oeffentlich sichtbar und liess sich sauber entfernen.

Bei den externen Providern sind exakt diese CNAMEs anzulegen:

| Provider-Record | Ziel |
|---|---|
| `_acme-challenge.stream.horads.de` | `_acme-challenge.stream.horads.de.acme.jit-creatives.de.` |
| `_acme-challenge.imcor.de` | `_acme-challenge.imcor.de.acme.jit-creatives.de.` |
| `_acme-challenge.www.imcor.de` | `_acme-challenge.www.imcor.de.acme.jit-creatives.de.` |
| `_acme-challenge.db.imcor.de` | `_acme-challenge.db.imcor.de.acme.jit-creatives.de.` |
| `_acme-challenge.config.imcor.de` | `_acme-challenge.config.imcor.de.acme.jit-creatives.de.` |
| `_acme-challenge.jonaks.com` | `_acme-challenge.jonaks.com.acme.jit-creatives.de.` |
| `_acme-challenge.www.jonaks.com` | `_acme-challenge.www.jonaks.com.acme.jit-creatives.de.` |
| `_acme-challenge.cloud.naturkindergarten-moehringen.de` | `_acme-challenge.cloud.naturkindergarten-moehringen.de.acme.jit-creatives.de.` |
| `_acme-challenge.mail.steinba.ch` | `_acme-challenge.mail.steinba.ch.acme.jit-creatives.de.` |
| `_acme-challenge.cloud.steinba.ch` | `_acme-challenge.cloud.steinba.ch.acme.jit-creatives.de.` |

Provider-UIs, die den Zonennamen automatisch anhaengen, erhalten links nur den
relativen Record-Namen. Nach jeder Aenderung muessen CNAME und Ziel ueber einen
oeffentlichen Resolver geprueft werden, bevor das zugehoerige Ingress-TLS
aktiviert wird.

Ein blosses `Certificate Ready=True` reicht nicht: Zu jeder Ausstellung wird
der erzeugte `Challenge` kontrolliert. Der aktuelle unselektierte
Catch-all-HTTP01-Solver muss vor der Massenanforderung entfernt oder auf
ausdruecklich benannte Ausnahmezonen begrenzt werden.

## Phase 3: `.246` pinnen und echte Client-IP erhalten

Der nginx-Service besitzt live `.246`, die Cilium-IPAM-Konfiguration weist aber
nur den Pool `.246-.249` aus. Die IP muss am Service deklarativ auf `.246`
fixiert werden. Die derzeit globale L2-Policy soll durch explizite Policies fuer
die benoetigten LoadBalancer ersetzt werden. Dabei muss Mailman `.247` weiterhin
angekuendigt werden; eine nginx-exklusive Policy wuerde den produktiven
LMTP-Pfad abschalten. Vor der Aenderung werden alle aktuellen LoadBalancer-IPs
und L2-Leases inventarisiert.

`externalTrafficPolicy: Local` ist keine einfache Loesung: Cilium L2
Announcements koennen die VIP auf einem Node ohne lokalen nginx-Pod announcen.
Genau diese Klasse von Fehler verursachte bereits einen Ausfall.

Der Cluster verwendet Cilium `1.16.5` mit den Standardpfaden SNAT/VXLAN. Eine
DSR-/Hybrid-Umstellung ist daher kein isolierter `.249`-Test, sondern eine
clusterweite CNI- und gegebenenfalls Tunnelmigration. Sie kann bestehende
Verbindungen sowie `.246`, Mailman `.247` und NodePorts beeinflussen und braucht
einen eigenen Wartungs- und Rollbackplan.

Zu vergleichen sind:

1. Cilium DSR/Hybrid mit `externalTrafficPolicy: Cluster` und erhaltener
   Source-IP. Dafuer muessen Kompatibilitaet, MTU, Geneve/native Routing,
   Upgrade-Pfad und vollstaendiger Cilium-Rollback bewertet werden.
2. Ein endpoint-aware L2-LoadBalancer, der `externalTrafficPolicy: Local`
   zuverlaessig unterstuetzt.

Erst nach der Plattformentscheidung kann `.249` als Canary-IP dienen. Fuer
echte externe Source-IP- und Rueckwegtests braucht der Canary ausserdem einen
temporaeren, dokumentierten UDM-Portforward oder einen gleichwertigen externen
Testpfad. Der Canary ersetzt keinen Failover-Test der produktiven `.246`.

Abnahmekriterien des Canary:

```text
echte externe IPv4 im nginx-Log
keine Uebernahme eines gespooften X-Forwarded-For
funktionierender Wechsel des L2-Lease-Holders
kein Ausfall bei nginx-Pod- oder Node-Neustart
korrekter Rueckweg ohne asymmetrisches Routing
```

Die bestehende nginx-Konfiguration darf nach dem Direkt-Cutover nicht weiterhin
beliebige XFF-Werte akzeptieren, nur weil der SNAT-Peer in `192.168.2.0/24`
liegt.

## Phase 4: CrowdSec-Enforcement verlagern

Die Cluster-CrowdSec-Installation ist aktuell Detection-only. Die beiden
Firewall-Bouncer auf `.15` liegen nach dem Direkt-Cutover nicht mehr im
Traffic-Pfad.

Vor Freigabe ist eine der folgenden Varianten umzusetzen und zu dokumentieren:

1. HTTP-Bouncer im Kubernetes-Ingress-Pfad vor der Anwendung.
2. Dynamisches Cilium-/Firewall-Enforcement aus CrowdSec-Entscheidungen.
3. Explizit akzeptiertes gleichwertiges Enforcement auf der UDM.

Ein kontrollierter Test muss eine Test-IP sperren und wieder freigeben, ohne eine
Node-, Pod- oder Proxy-IP zu blockieren. Erst nach diesem Test duerfen die
Bouncer auf `.15` entfallen.

## Phase 5: Funktionstest direkt gegen `.246`

Jeder Host wird vor dem WAN-Cutover lokal mit festem SNI getestet:

```bash
HOST=cloud-dev.savar.de
curl --resolve "$HOST:443:192.168.2.246" "https://$HOST/status.php"
openssl s_client -connect 192.168.2.246:443 -servername "$HOST" </dev/null
```

Die TLS-Abnahme validiert pro SNI Hostname, Chain, Ablaufdatum, SAN und das
erwartete Secret. Zusaetzlich muessen die betroffenen ArgoCD-Applications
`Synced/Healthy` sein und jeder Ingress nach dem letzten Rollout ein aktuelles
`AddedOrUpdated`-Event besitzen; alte Events koennen ablaufen und sind kein
dauerhafter Zustandsnachweis.

Zusaetzlich pruefen:

- OIDC-Discovery und echter Login ueber `auth.savar.de`.
- Nextcloud Login, WebDAV, Upload/Download und `notify_push:setup`.
- GitLab Web, Clone/Push und Registry Push/Pull.
- Mailman Web, LMTP, REST, Listenmail und Moderation.
- Roundcube Login, Identitaeten, Kontakte, IMAP und SMTP.
- WordPress Frontend, `/wp-admin` und Redirects.
- Collabora mit realem Oeffnen, Bearbeiten und Speichern eines Dokuments.
- S3 Upload/Download, Icecast-Langzeitstream und WebSockets.
- Alle Hosts aus `legacy-proxy` und Binaergewitter.
- Gatus sowie nginx-, cert-manager-, CrowdSec- und Anwendungslogs.

Vor Ausfuehrungsfreigabe wird daraus eine vollstaendige Hostmatrix mit diesen
Pflichtfeldern erstellt:

| Host | Disposition | Testpfad/Protokoll | Erwartung | Owner | Ergebnis/Sign-off |
|---|---|---|---|---|---|
| auszufuellen | migrieren/abschalten | auszufuellen | auszufuellen | auszufuellen | offen |

## Phase 6: UDM-Cutover

Vorher:

1. UniFi-Konfiguration exportieren.
2. Aktuelle Regeln fuer TCP 80, 443 und 2525 mit Screenshots und Zieladressen
   dokumentieren.
3. Rollback auf `.15` vorbereiten.
4. Laufende Langzeitverbindungen und geplante Wartungen pruefen.

Cutover-Reihenfolge:

1. XFP-basiertes `redirect-to-https` ist auf `.246` aktiviert und sowohl hinter
   Traefik als auch direkt getestet.
2. TCP 80 bleibt zunaechst auf `.15` und liefert weiterhin den bestehenden
   HTTPS-Redirect.
3. TCP 443 von `.15` auf `.246` umstellen.
4. Vollstaendige externe TLS- und Anwendungs-Abnahmematrix ausfuehren.
5. Waehrend TCP 80 noch auf Traefik zeigt, `nginx.org/ssl-redirect: "true"` per
   GitOps aktivieren. Direkt gegen `.246:80` pruefen, dass auch eine Anfrage mit
   gespooftem `X-Forwarded-Proto: https` zwingend auf HTTPS umgeleitet wird.
6. Erst danach TCP 80 von `.15` auf `.246` umstellen; es darf zu keinem
   Zeitpunkt Klartext-Inhalt ausliefern.
7. `.15` eingeschaltet und unveraendert als Rollback bereithalten.

Falls die UDM beide Regeln nur gemeinsam aendern kann, werden 80 und 443 atomar
umgestellt. Vorher wird WAN-TCP-80 temporaer gesperrt. Nach dem atomaren Wechsel
wird `ssl-redirect` aktiviert und direkt inklusive XFP-Spoof-Test verifiziert;
erst danach wird Port 80 wieder freigegeben. Der XFP-basierte Redirect allein
reicht fuer diesen Zwischenzustand nicht. Ein Zustand mit erreichbarer `.246`
auf Port 80 und deaktiviertem `ssl-redirect` ist nicht zulaessig.

Port 2525 ist ein eigener Mail-Cutover und wird nicht zusammen mit 80/443
entfernt.

## Phase 7: Postfix und Legacy-Daten beenden

### Port 2525 vorwaerts entfernen

Der Zielzustand ist nicht `2525 -> .247`: LMTP auf `.247:8024` bleibt intern und
wird nur von mx02/mx03 angesprochen. Der alte oeffentliche Portforward wird
ersatzlos entfernt, sobald der SMTP-/MX-Pfad vollstaendig uebernommen hat.

Voraussetzungen:

1. Alle Konfigurationen und Runbooks nach `lists.jitmail.de:2525` und
   `192.168.2.15:25` durchsuchen; jeder produktive Absender nutzt normale MX-
   Zustellung beziehungsweise den freigegebenen Mail-Gateway-Pfad.
2. mail04 sowie mx02/mx03 live pruefen: mx02/mx03 liefern fuer alle acht
   Transport-Domains direkt an `.247:8024`.
3. Sieben Tage lang keine neue produktive Verbindung oder Queue-ID auf Postfix
   `.15:25` nachweisen; Start und Ende des Beobachtungsfensters dokumentieren.
4. Kontrollierte Listenmail ueber den normalen externen MX-Pfad zustellen und
   Archivierung, Moderation und Verteilung pruefen.

Ausfuehrung:

1. UDM-Regel TCP 2525 deaktivieren, aber als Rollback dokumentiert behalten.
2. Von einem externen Netz bestaetigen, dass 2525 geschlossen ist.
3. Normale MX-Zustellung zu mehreren repraesentativen Listendomains wiederholen.
4. Weitere sieben Tage Postfix-, MX- und Mailman-Queues sowie Logs beobachten.

Postfix darf erst danach gestoppt werden, wenn mx02/mx03 weiterhin direkt an
`.247:8024` liefern, alle acht Transport-Domains getestet wurden und alle Queues
leer bleiben. Falls ein produktiver Client Port 2525 noch benoetigt, wird der
Cutover abgebrochen und zuerst ein expliziter SMTP-Ersatz auf den Mail-Gateways
entworfen; der Port wird niemals direkt auf LMTP weitergeleitet.

Fuer jede Legacy-Datenbank:

1. Konsistenten Dump und Dateisystem-Backup erstellen.
2. Checksummen, Verschluesselung und externen Aufbewahrungsort dokumentieren.
3. Einen Test-Restore in eine isolierte Instanz erfolgreich durchfuehren.
4. Aktive Verbindungen und Schreibzugriffe ausschliessen.
5. Aufbewahrungs- und Loeschdatum dokumentieren.
6. Container stoppen, aber Daten und Compose-Dateien noch nicht loeschen.

Die Mailman-Alt-Datenbank bleibt bis zum Ende der vereinbarten
Migrations-Rollback-Frist erhalten.

## Phase 8: Soft-Off und Abschaltung

1. Direkten `.246`-Betrieb mindestens sieben Tage beobachten.
2. Traefik auf `.15` stoppen; VM bleibt eingeschaltet.
3. Nach bestandenen Einzel-Gates Postfix, Bouncer und Legacy-Datenbanken stoppen.
4. Weitere 72 Stunden beobachten.
5. VM-Snapshot sowie externe Konfigurations- und Datenbackups erstellen.
6. VM herunterfahren und Autostart deaktivieren.
7. Nach 14 bis 30 Tagen Karenz endgueltig entfernen.
8. Erst danach alte Trust-Eintraege, Bouncer-Registrierungen, DNS-Namen und
   Ansible-Inventar bereinigen.
9. Den alten globalen Cloudflare-API-Key nach Ende der Rollback-Frist rotieren
   oder widerrufen und alle Compose-, Backup- und Snapshot-Kopien inventarisieren.

## Rollback

Vor dem Web-Rollback wird zuerst entweder die Traefik-Rollback-Konfiguration auf
HTTPS zu `.246:443` umgestellt und verifiziert oder die Redirect-Aktivierung per
Git revertiert und von ArgoCD ausgerollt. Erst danach werden die UDM-Regeln fuer
TCP 80/443 auf `.15` zurueckgesetzt. Die umgekehrte Reihenfolge erzeugt sofort
den bekannten Redirect-Loop.

Falls fuer den Source-IP-Erhalt Cilium-, Tunnel- oder L2-Komponenten geaendert
wurden, gilt deren separat getesteter Plattform-Rollback als Voraussetzung fuer
den Gesamt-Cutover. Ein UDM-Rollback allein repariert keine fehlerhafte
Cluster-Netzwerkebene.

Mail-Rollback ist getrennt:

```text
UDM 2525 -> 192.168.2.15:25
Postfix transport map und Relay-Trust wiederherstellen
Queue und Zustellung zu 192.168.2.247:8024 pruefen
```

`.15` wird bis zum Ende der Karenz weder geloescht noch neu aufgesetzt.

## Review-Fragen

1. Soll die Source-IP mit Cilium DSR/Hybrid geloest werden, oder soll ein
   endpoint-aware L2-LoadBalancer `externalTrafficPolicy: Local` ermoeglichen?
2. Welche oeffentlichen Zonen sind tatsaechlich auf `dns01` autoritativ und fuer
   den vorhandenen RFC2136-TSIG freigegeben?
3. Sollen Cloudflare-Zonen direkt per API-Token oder per einmaliger
   `_acme-challenge`-CNAME-Delegation bedient werden?
4. Welche Enforcement-Variante ersetzt die CrowdSec-Firewall-Bouncer auf `.15`?
5. Werden `home.savar.de`, `tools.kniff.eu` und `netbox.kniff.eu` migriert oder
   abgekuendigt?
6. Wie lang sollen Mailman-Altbestand und Legacy-Datenbankbackups aufbewahrt
   werden?
