# Abschaltplan fuer docker15 (192.168.2.15)

Status: **✅ WAN-Cutover vollzogen am 13.09.2026.** Die UDM leitet 80 und 443 auf
`192.168.2.246`; `.15` ist aus dem Web-Pfad heraus. Alle 42 externen Hosts verhalten sich
wie im Referenzlauf, `stream.horads.de` lief ohne eine einzige Unterbrechung durch, und
die echte Client-IP kommt nachweislich an — gefaelschtes `X-Forwarded-For` wird verworfen.

**12 der 13 harten Gates sind erfuellt**; das verbleibende Kaestchen (CrowdSec-Enforcement)
ist ausdruecklich **kein** Gate. Details und Messwerte unter „Cutover vollzogen".

Offen sind jetzt noch: die vier vorgeladenen Zertifikate auf cert-manager
umstellen (vor dem 24.10.) und `.15` beobachten und abschalten. Das
steinba.ch-Mailzertifikat ist **seit dem 13.09.2026 erledigt** — es wird jetzt
im Cluster ausgestellt und von cfgmgmt01 nach mail05 ausgerollt.

Planstand: 2026-09-13 (Cutover vollzogen; vorherige Staende 2026-09-12 mit
TLS-Rollout/redirect-to-https/Source-IP, 2026-09-11, 2026-09-01 und 2026-07-30).

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

### Am 12.09.2026 erledigt: Phase 2 ausgerollt

PR **#149** (`41ec100`) loest die veralteten PRs #79/#80 ab (beide lagen 22 Commits
hinter `main` und deckten inzwischen entfernte Hosts ab; beide geschlossen).

Reihenfolge bewusst dreistufig gefahren, damit ein Solver-Fehler nicht 20 echte
Zertifikate gleichzeitig verbrennt:

| Schritt | Ergebnis |
|---|---|
| 1. Nur `infra-cert-manager` syncen | Beide ClusterIssuer `Ready`: `letsencrypt-prod` und neu `letsencrypt-staging`. |
| 2. Drei Staging-Proben abwarten | `dns01-staging-rfc2136`, `dns01-staging-rfc2136-follow` und `dns01-staging-cloudns` alle `Ready=True` — je eine pro Solver-Klasse. |
| 3. Elf App-Syncs | `legacy-proxy`, `roundcube`, `collabora`, `kimai`, `mailman`, `paperless-ngx`, `phpmyadmin`, `wordpress-1`, `wordpress-2`, `expense-tracker`, `gatus-public` — alle `Succeeded`, danach `Synced/Healthy`. |
| Ergebnis | Bestand 21 → **36 Zertifikate, ausnahmslos `Ready=True`**, letzte Ausstellung 570 s nach den Syncs, keine offene Challenge, kein fehlgeschlagener Order. |

**Abnahme gegen `.246`:** fuer alle 37 Namen per SNI geprueft, dass der angefragte
Name in der SAN-Liste des tatsaechlich ausgelieferten Zertifikats steht.

> **Falle bei der Abnahme:** Der CN taugt als Nachweis nicht. `gesinefranze.jit-creatives.de`
> liefert `CN=umdiehand.jit-creatives.de`, `mgmt02.jit-creatives.de` liefert
> `CN=www.jit-creatives.de`, `jit.cloud` liefert `CN=cloud.savar.de` — alle drei korrekt,
> weil es Sammelzertifikate sind. Immer gegen `openssl x509 -noout -ext subjectAltName`
> pruefen, nie gegen den Subject-CN.

> **Falle bei der Diagnose (kostete fast eine Stunde Scheinfehler):** cert-manager laeuft
> mit `--dns01-recursive-nameservers=1.1.1.1:53` **und**
> `--dns01-recursive-nameservers-only`; der Self-Check fragt also ausschliesslich 1.1.1.1.
> Die `jit.services`-Staging-Probe blieb haengen, obwohl der TXT-Record auf allen vier
> autoritativen ClouDNS-Servern stand und 8.8.8.8/9.9.9.9 ihn sahen — 1.1.1.1 hielt einen
> negativen Cache-Eintrag (SOA-Minimum 3600). **Diagnose-Reihenfolge: erst die
> autoritativen NS fragen, dann 1.1.1.1; weicht nur 1.1.1.1 ab, ist es Cache und kein
> Solver-Fehler.** Verbesserungsvorschlag: mehrere Resolver bzw. die autoritativen NS
> eintragen, sonst trifft diese Verzoegerung jede kuenftige DNS-01-Ausstellung.

Nebenbefund: `gemeinsam-fuer-halbe.de` ist an der Registry **nicht mehr zu Cloudflare
delegiert**, sondern auf `ns/ns3.jitcreatives.de` — der lange offene NS-Wechsel ist
vollzogen. Damit wirken dns01-Aenderungen fuer diese Zone jetzt auch oeffentlich.

### Nachzuegler-Zertifikate nach dem Cutover

**Entscheidung Ingo, 12.09.2026:** Die vier beim TLS-Rollout ausgesparten Namen werden
**unmittelbar nach dem Port-80-Cutover per HTTP-01 ausgestellt**. Kein DNS-01, kein
Provider-Kontakt, kein Warten auf fremde CNAME-Eintraege.

| Name | Ingress | Warum erst nach dem Cutover |
|---|---|---|
| `stream.horads.de` | legacy-proxy | HTTP-01 loest erst, wenn Port 80 auf `.246` zeigt |
| `mail.steinba.ch` | roundcube | dito |
| `cloud.steinba.ch` | legacy-proxy | dito |
| `cloud.naturkindergarten-moehringen.de` | legacy-proxy | CNAME beim Provider fehlt; HTTP-01 umgeht das Problem statt es zu loesen |

Voraussetzungen, die vorher stehen muessen:

1. **`naturkindergarten-moehringen.de` wird im ClusterIssuer verschoben, nicht
   hinzugefuegt.** Die Zone steht heute bereits in Solver 3 (DNS-01 rfc2136,
   `cnameStrategy: Follow`, gemeinsam mit `imcor.de` und `jonaks.com`) — und scheitert
   genau dort, weil der `_acme-challenge`-CNAME beim Provider fehlt. Sie muss aus
   Solver 3 **entfernt** und in den HTTP-01-Solver eingetragen werden. Stuende sie in
   beiden, gewaenne weiterhin der DNS-01-Follow-Solver und nichts waere gewonnen.
   Endstand: Solver 3 = `imcor.de` + `jonaks.com`; HTTP-01-Solver = `horads.de` +
   `steinba.ch` + `naturkindergarten-moehringen.de`, weiterhin explizit begrenzt,
   kein Catch-all.
2. Port 80 zeigt auf `.246` und `nginx.org/ssl-redirect` steht fuer diese Hosts auf
   `false`, sonst beantwortet nginx die ACME-Anfrage mit einem Redirect und die
   Challenge scheitert. Jeder betroffene Ingress traegt
   `acme.cert-manager.io/http01-edit-in-place: "true"`.
3. **Erst einzeln ausstellen, dann zusammenfassen.** Jeder Name bekommt zunaechst ein
   eigenes `Certificate`; ein scheiternder Name soll kein bestehendes Sammelzertifikat
   mitreissen.

Reihenfolge im Cutover-Fenster: NAT umstellen → Erreichbarkeit von `.246:80` von aussen
pruefen → die vier Zertifikate anfordern → per SAN-Pruefung abnehmen (nicht per CN).

### Unveraendert gegenueber 01.09.2026

| Bereich | Live-Befund 11.09.2026 |
|---|---|
| ArgoCD | Nur `root` hat `syncPolicy.automated` (38 Applications). OutOfSync/Degraded unveraendert: `app-mastodon`, `app-nextcloud-yealink-phonebook`, `infra-cilium`, `infra-cnpg`, `infra-mariadb-operator`, `infra-monitoring`. |
| Cilium | `v1.16.5`, globale `default-l2`-Policy, Pool `default-pool` (2 frei). |
| nginx-LB | `.246` live, aber **nicht deklarativ gepinnt** (`loadBalancerIP`/`lbipam.cilium.io/ips` leer). `externalTrafficPolicy: Cluster`. Mailman `.247` ist gepinnt. |
| Real-IP | `set-real-ip-from: 192.168.2.0/24`, `real-ip-header: X-Forwarded-For` — nach dem Direkt-Cutover spoofbar. |
| CrowdSec im Cluster | Agents + LAPI, kein Bouncer. |
| cert-manager | ~~nur `letsencrypt-prod`; PRs #79/#80 seit 30.07. offen.~~ **Ueberholt am 12.09.2026** durch PR #149, siehe naechster Abschnitt. |

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
   `.29`, `.242`). Am 11.09. neu erzeugt, am 12.09. ausgerollt. Siehe „DR-Edge Potsdam“.
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
   rollt ein Merge nichts aus und ein Git-Revert repariert nichts. Analyse 11.09.2026
   (`argocd app diff --core`, Repo-Server-Fix vom 24.08. ist live):

   | App | Diff | Risiko beim Sync | Vorgehen |
   |---|---|---|---|
   | `app-mastodon` | ~~haengende Loeschung~~ | — | **erledigt 11.09.**: Hook-Finalizer entfernt, App und Namespace-Reste weg |
   | `infra-mariadb-operator` | Tracking-Annotationen + konvertierte `VMServiceScrape` | gering | **erledigt 11.09.** (PR #144, Sync): `Synced/Healthy` |
   | `infra-monitoring` | Webhook-Zertifikat-Drift; Scrape-Services nach `kube-system` | gering | **erledigt 11.09.** (PR #144, Sync): `Synced/Healthy` |
   | `app-nextcloud-yealink-phonebook` | Synced, Degraded (Platzhalter-Passwort) | keins | Secret setzen oder bewusst so lassen |
   | `infra-cilium` | nur Checksummen-Annotation; `cilium-config` unterscheidet sich in 3 leeren Schluesseln (`debug-verbose`, `nodeport-addresses`, `policy-cidr-match-mode`) | **rollender Neustart aller Cilium-Agenten** ohne funktionale Aenderung | Wartungsfenster, mit Cilium 1.20 und Phase 3 zusammenlegen |
   | `infra-cnpg` | Operator 1.25.0 → 1.30.0 | Neustart aller 6 Cluster | **erledigt 11.09. abends** (PRs #145 + Ergebnis-PR): Upgrade gefahren, ~1 min Ausfall je Cluster, `Synced/Healthy`. Backups davor und danach `completed`; `crowdsec-pg`/`expense-pg` haben weiterhin keine Sicherung ausser logischen Dumps |

   **Stand 13.09.2026: alle sechs Apps dieser Tabelle sind erledigt, und mit ihnen der
   gesamte Bestand — 36 von 36 stehen `Synced/Healthy`.** `infra-cilium` wurde im
   Wartungsfenster gesynct, `app-nextcloud-yealink-phonebook` mit PR #160 behoben (die
   Ursache war ein von Nextcloud mit 401 abgelehntes App-Passwort, kein Platzhalter).
   Das fleet-weite `automated` ist bewusst weiterhin NICHT aktiviert — das ist eine eigene
   Risikoentscheidung, siehe „Offene Entscheidungen“, Punkt 2.
7. ~~PRs #79/#80 nach #143 neu aufsetzen~~ — erledigt 12.09.2026 durch **PR #149**;
   beide Alt-PRs geschlossen, Cloudflare-Solver und `cloudflare-api-key` sind raus.
8. ~~Staging zuerst~~ — erledigt 12.09.2026. Die drei Staging-Proben liefen vor den
   Produktionszertifikaten, der Catch-all-HTTP01-Solver ist auf `horads.de` und
   `steinba.ch` begrenzt.
8a. ~~`nginx.org/redirect-to-https: "true"` aktivieren~~ — erledigt 12.09.2026
   (PRs #152 und #153). 28 Ingresses auf `"true"`, drei bewusst auf `"false"`.
   `ssl-redirect` bleibt bis zum 443-Cutover ueberall `false`.

### Weiterhin offen und entscheidungsbeduerftig

9. ~~Phase 3 Plattformentscheidung (Cilium DSR/Hybrid gegen endpoint-aware L2),
   gemeinsam mit dem Cilium-Update auf `1.20.0`. Groesster Einzelposten, Voraussetzung
   fuer den WAN-Cutover.~~ — **HINFAELLIG seit 12.09.2026.** Variante A loest Phase 3
   ohne diese Entscheidung: DaemonSet auf allen Nodes plus `externalTrafficPolicy:
   Local`, komplett innerhalb von `infra-ingress-nginx`. Weder DSR noch ein Austausch
   des L2-Mechanismus waren noetig. **Folge: das Cilium-1.20-Upgrade ist normale
   Wartung und kein Cutover-Blocker mehr** — siehe „Offene Entscheidungen“.
10. ~~`cloud.naturkindergarten-moehringen.de`: CNAME beim Provider anlegen lassen oder
    den Namen aus dem Zertifikat nehmen.~~ — **entschieden 12.09.2026: per HTTP-01
    direkt nach dem Cutover ausstellen.** Kein Provider-Kontakt noetig. Siehe
    „Nachzuegler-Zertifikate nach dem Cutover“.
11. ~~Potsdam-DR-Edge fertigstellen~~ — erledigt 12.09.2026. Offen bleiben dort nur der
    CrowdSec-Bouncer auf der toten GitLab-LAPI und die fehlenden UCG-Forwards 80/443.
12. Optional: **Phase 4 CrowdSec-Enforcement** im neuen Pfad.

~~Ein WAN-Cutover-Termin wird erst nach Schritt 6 bis 9 sinnvoll gesetzt.~~
**Neu formuliert am 13.09.2026:** Schritt 9 ist hinfaellig, Schritt 7 und 8 sind
erledigt. Was einen Termin heute noch blockiert, steht gebuendelt unter
„Offene Entscheidungen“ — im Kern nur noch der ArgoCD-Freeze, der Spoof-Test und
die Klaerung der steinba.ch-Kette.

## Offene Entscheidungen (Stand 13.09.2026)

Gebuendelt, was heute noch eine Entscheidung braucht. **Die Empfehlungen sind Vorschlaege,
nicht getroffene Entscheidungen** — solange hier nichts abgehakt ist, gilt der Stand
darueber.

### 1. Widersprueche im Plan selbst

**1a — Punkt 9 („Phase 3 Plattformentscheidung“) ist hinfaellig.** Bereits oben
korrigiert. Er stand als *Voraussetzung fuer den WAN-Cutover*, obwohl Variante A Phase 3
am 12.09. ohne ihn geloest hat.
**Empfehlung:** so belassen und das Cilium-1.20-Upgrade als gewoehnliche Wartung planen.
Es blockiert den Cutover nicht mehr.

**1b — ✅ ENTSCHIEDEN am 13.09.2026: „ja nach dem Cutover“.** Das Gate ist gestrichen,
der Punkt ist Pflichteintrag der Cutover-Checkliste. **Weiterhin offen ist allein der
Verteilmechanismus** — meine Empfehlung ist der Cron auf `cfgmgmt01`, weil er
`steinbach-cert-deploy.sh` fast unveraendert weiterverwendet und kein neuer SSH-Key mit
Schreibrecht auf mail05 entsteht:

| Variante | Vorteil | Nachteil |
|---|---|---|
| **✅ GEWAEHLT (13.09.2026): Cron auf `cfgmgmt01` liest das Kubernetes-Secret (`kubectl get secret`)** | uebernimmt `steinbach-cert-deploy.sh` fast unveraendert, nur die Quelle aendert sich; kein neuer Schreibzugriff auf mail05 | cfgmgmt01 braucht dauerhaft Cluster-Zugriff (hat es ohnehin) |
| ~~CronJob im Cluster mit SSH-Key auf mail05~~ (verworfen) | laeuft dort, wo das Secret entsteht | neuer SSH-Key mit Schreibrecht auf mail05 |

**Damit ist 1b vollstaendig entschieden.** Umsetzung nach dem Cutover, als Pflichteintrag
der Cutover-Checkliste. Offene Detailpunkte fuer die Umsetzung: welcher Kubernetes-Zugang
auf cfgmgmt01 verwendet wird (eigener ServiceAccount mit Leserecht nur auf dieses Secret
statt des vollen Kubeconfigs) und wohin der bisherige `.15`-Cron abgeschaltet wird.

⚠️ **Die Frist bleibt unabhaengig davon scharf:** ab dem Port-80-Schwenk kann `.15` nicht
mehr erneuern, das Zertifikat laeuft am **04.12.2026** ab. Faellt der Cutover hinter
Anfang November, muss der Umbau im selben Fenster miterledigt sein.

### 2. Gate „ArgoCD-Freeze aufheben“ — drei Teilentscheidungen

| App | Lage 13.09.2026 | Empfehlung |
|---|---|---|
| `infra-kite` | OutOfSync, **alle 8 Ressourcen**; Renovate-Bump auf kite v0.15.0 (#142) wurde nie gesynct | syncen — internes Werkzeug, geringes Risiko, danach gruen |
| `app-nextcloud-yealink-phonebook` | `Degraded` wegen Platzhalter-Passwort | echtes Passwort setzen **oder** die App entfernen; dauerhaft Degraded verwaessert das Gate |
| ~~`infra-cilium`~~ | **✅ erledigt 13.09.2026.** Der befuerchtete Preis blieb aus: 1 s Aussetzer auf `.246`, keiner auf `.247` | — |

Darauf aufbauend: **`automated` fleet-weit wieder einschalten, oder manuell bleiben?**
Heute hat genau **eine** von 36 Apps `automated`.
**Empfehlung:** das Gate umformulieren auf „alle Apps `Synced/Healthy`, Sync darf manuell
bleiben“. Der Freeze war eine Reaktion auf das kaputte Helm-Rendering (behoben am 24.08.);
ihn fleet-weit aufzuheben ist eine eigene Risikoentscheidung und sollte nicht als
Nebenwirkung des Cutovers passieren.

**Ingos Frage vom 13.09.2026: „Wann kann man das Freeze-Gate aufheben?“ — Antwort war:
an einem Abend. Tatsaechlich wurden alle drei Punkte am selben Tag erledigt.**
Aufgeschluesselt, was jeweils gefehlt hatte:

| App | Was fehlt | Aufwand | Wer |
|---|---|---|---|
| ~~`infra-kite`~~ | **✅ erledigt 13.09.2026.** Auf Chart `0.15.0` gesynct. Dabei fiel auf, dass der Pod zweimal neu startete: bis „Kite server started on port 8080“ vergehen je nach Lauf 3 bis ueber 40 s, waehrend die Liveness nur 40 s toleriert. Mit **PR #161** per Kustomize-Patch ein `startupProbe` (30 × 5 s) nachgeruestet — das Chart kennt den Schluessel in `values.yaml` nicht. Danach `1/1` nach 10 s mit **0 Neustarts** | — | — |
| ~~`app-nextcloud-yealink-phonebook`~~ | **✅ erledigt 13.09.2026.** Ursache war nicht ein Platzhalter, sondern ein von Nextcloud mit **401** abgelehntes App-Passwort; `/healthz` lieferte deshalb dauerhaft 503. Behoben mit **PR #160** (neues App-Passwort). Da die App nur alle `REFRESH_INTERVAL=900` s neu authentifiziert, wurde der Pod erst rund 15 min nach dem Sync ready — `refreshed phonebook with 17 contacts`, danach `Synced/Healthy` | — | — |
| ~~`infra-cilium`~~ | **✅ erledigt 13.09.2026 im Wartungsfenster.** Gemessen mit 1-s-Aufloesung: **1 Timeout von 73** Messpunkten auf `.246`, **0** auf `.247` (LMTP). Alle 7 Agenten ersetzt, je 0 Neustarts, danach 151 Pods clusterweit ohne einen einzigen nicht bereiten | — | — |

**⚠️ Neu seit dem 12.09. und beim Cilium-Sync zu beachten:** `.246` laeuft jetzt ueber
L2-Announcements mit `externalTrafficPolicy: Local`. Startet der Cilium-Agent auf der
**announcenden** Node neu, kann die VIP-Ankuendigung kurz aussetzen — der Cilium-Sync
beruehrt damit erstmals den Ingress-Pfad. Deshalb **vor** dem Cutover fahren, mitmessen,
und die operative Regel aus Phase 3 anwenden: erst den L2-Lease wegschieben, dann die
betroffene Node anfassen.

### 3. ✅ Erledigt: die Abnahme-Testreihe ist gefahren (13.09.2026)

Ingo hat die Fehlerinjektion freigegeben. Ergebnis: **Spoof-Test negativ, L2-Lease-Wechsel
verlustfrei (0 von 45), Pod-Neustart auf der announcenden Node ~2 s (1 von 45).**
Messwerte und die daraus folgende operative Regel — **erst den Lease wegschieben, dann den
Pod neu starten** — stehen unter Phase 3, „Abnahmekriterien“.

**Offen bleibt nur die Bewertung:** das Gate lautet „kein Ausfall bei nginx-Pod- oder
Node-Neustart“. Gemessen sind ~2 s, also nicht null. **Empfehlung:** Gate als erfuellt
betrachten und stattdessen die operative Regel verbindlich machen — mit ihr sind es null.
Wer strikt null ohne Verfahrensdisziplin will, braucht endpoint-aware Announcement (BGP)
statt L2.

### 3b. Das Cilium-Fenster (13.09.2026) — was es wirklich gekostet hat

Gefahren mit durchgehender Messung auf beiden LoadBalancer-IPs, 1-s-Aufloesung:

| Messung | Ergebnis |
|---|---|
| `.246` (HTTP, `externalTrafficPolicy: Local`) | **1 Timeout von 73** Messpunkten |
| `.247` (Mailman-LMTP, TCP) | **0** Ausfaelle |
| L2-Lease | **wanderte gar nicht**, durchgehend `kellerio-wrk2` |
| Cilium-Agenten | alle 7 ersetzt, je **0** Neustarts |
| danach | 151 Pods clusterweit, **kein einziger nicht bereit**; 36/36 Zertifikate `Ready`; alle Apps gruen |

**Zwei Dinge, die vorher unklar waren und jetzt Zahlen haben:**
- Der DaemonSet faehrt mit `maxUnavailable: 2`, nimmt also **zwei** Agenten gleichzeitig
  herunter. Bei 7 Nodes sind das rund vier Wellen.
- Die L2-Lease-Dauer betraegt **15 s**. Der befuerchtete Worst Case waere also ein
  15-s-Loch gewesen, wenn der Agent auf der announcenden Node stirbt und der Lease
  auslaeuft. Eingetreten ist er nicht: der Lease blieb die ganze Zeit bei `wrk2`, der
  Aussetzer betrug **eine Sekunde**. Der Agent war schneller zurueck, als der Lease
  ablief.

**Konsequenz fuer den WAN-Cutover:** ein Cilium-Sync kostet nach heutiger Messung rund
eine Sekunde auf dem Ingress-Pfad. Das ist planbar und braucht kein Sonderfenster mehr —
die Betriebsregel aus Phase 3 (erst Lease wegschieben, dann Node anfassen) bleibt fuer
gezielte Eingriffe an einzelnen Nodes trotzdem die bessere Reihenfolge.

**Nebenbefund:** vor dem Rollout trug ein Agent (`cilium-mmq5m`) **280 Neustarts** in
46 Tagen. Alle neuen Pods stehen bei 0. Ob das Muster wiederkehrt, ist zu beobachten —
die Ursache wurde nicht untersucht.

### 4. ✅ Erledigt: Monitoring bereinigt (13.09.2026, PR #164)

| Instanz | vorher | nachher |
|---|---|---|
| `status.jit.services` | 4 von 20 rot | **0 von 14 rot** |
| `status.jit-creatives.de` | 2 von 13 rot | **1 von 12 rot** |

Entfernt wurden die vier Checks auf bewusst abgeschaltete Dienste — `forgejo` und
`wordpress-3` (beide `replicas: 0` in Git), `mastodon` (App am 11.09. entfernt) und
`nextcloud-dev` (Backend `192.168.2.220` tot). **Jeder Eintrag ist durch einen Kommentar
ersetzt, der sagt, wann er zurueckzuholen ist** — nicht ersatzlos geloescht. Bei
`wordpress-3` steht dort ausdruecklich, dass Reaktivieren zweierlei heisst: den
`replicas: 0`-Patch entfernen **und** den fehlenden ServiceAccount anlegen.

> **🔴 Der eigentliche Ertrag: dabei kam ein echter Ausfall zum Vorschein.** Der
> verbleibende rote Punkt ist **GitLab** — `https://gitlab.jit-creatives.de/` liefert
> **500** aus GitLabs eigener Fehlerseite (`server: nginx`, `x-gitlab-meta`), die
> Health-Endpunkte `404`. Traefik auf edge01 routet korrekt, der DNS zeigt richtig; die
> Anwendung dahinter erbricht sich. **Das ging im Rauschen der vier bekannten roten Punkte
> unter.** Eigene Baustelle, hier nicht angefasst — aber genau der Fall, den die Luecke im
> Monitoring am 04.09. schon einmal verdeckt hat.

### 5. Erst danach: der Termin

Punkte 2 bis 4 sind am 13.09.2026 erledigt. Was fuer einen Termin noch fehlt, liegt bei
Ingo:

**✅ Die UDM-Bereinigung ist abgeschlossen (13.09.2026 nachgeprueft).** Von den
urspruenglich sieben veralteten Freigaben ist keine mehr da; auch die vier, die beim
ersten Nachzaehlen noch standen (`8443`→`.17`, `2233`→`.29`, `2001`→`.29`, `21`→`.15`),
sind entfernt. **Von den 30 verbliebenen Forwards zeigen auf `.15` nur noch `80` und
`443`** — also genau das, was der Cutover selbst umlegt.

⚠️ **Merkregel aus diesem Vorgang:** „ist umgesetzt“ wurde hier zweimal gemeldet und war
beim ersten Mal nur teilweise richtig. Der Ist-Stand laesst sich in Sekunden lesen, also
lesen statt glauben — der UniFi-Controller ueberschreibt SSH-Aenderungen, ein Blick ist
aber gefahrlos:

```text
ssh root@192.168.2.10 "ssh root@192.168.2.94 \
  'iptables -t nat -S UBIOS_PREROUTING_USER_HOOK | grep DNAT'"
```

Der UniFi-Konfigurationsexport als Rollback-Beleg ist am 13.09.2026 angelegt. Offen ist
damit nur noch der eigentliche DNAT-Schwenk 80/443 von `.15` auf `.246`.

Nur lesend pruefen laesst sich der Ist-Stand so (der Controller ueberschreibt
SSH-Aenderungen):

```text
ssh root@192.168.2.10 "ssh root@192.168.2.94 \
  'iptables -t nat -S UBIOS_PREROUTING_USER_HOOK | grep DNAT'"
```

### 6. Kleineres, aber offen

- Zwei ueberholte Branches auf GitHub: `feat/docker15-ingress-tls` (27 eigene Commits),
  `feat/docker15-phase12` (6). Beide PR-los und vor #143/#144/#147/#149 — loeschen oder
  archivieren? Ihre brauchbare Doku ist laengst auf `main`.
- cert-manager von `--dns01-recursive-nameservers-only=1.1.1.1` wegholen (mehrere Resolver
  oder die autoritativen NS). Ein negativer Cache dort sieht wie ein Solver-Fehler aus.
- Nach dem Cutover `set-real-ip-from` auf `192.168.2.15/32` verengen.
- Potsdam-DR-Edge: CrowdSec-Bouncer zeigt auf die tote GitLab-LAPI; UCG-Forwards 80/443
  fehlen.
- CT 8004 auf `.12`: derselbe latente IP-Konflikt wie bei CT 8020, ungeprueft.
- Vor CNPG 1.31: Migration auf das Barman-Cloud-Plugin (in-tree Barman entfaellt dort).
- Phase 4 CrowdSec-Enforcement — ausdruecklich **kein** Gate.

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
- **Rollout erledigt am 12.09.2026.** Der IP-Konflikt auf `192.168.23.20` (ESP-Geraet per
  UCG-DHCP) ist nach der Pool-Umstellung weg; MAC-Gegenprobe vor dem Start zeigte die
  CT-MAC. `--check --diff` und Rollout sauber (`failed=0`), Traefik laeuft mit **19 Routern**
  und ohne Dashboard-Label. SNI-Tests gegen `.20` liefern dieselben Statuscodes wie ueber
  `.15` (kimai 302, lists 301, www.jit-creatives 200, s3 200, cloud 302, imcor 301).
  Danach wieder gestoppt (Kalt-Standby).

Der UCG-DHCP-Bereich wurde am 11./12.09. verkleinert. **Merkregel fuer Potsdam:** vor dem
Start eines lange gestoppten Gastes `ip neigh show <ip>` gegen die MAC aus `pct config`
halten — ein IP-Konflikt aeussert sich als `Connection refused` mitten im Ansible-Lauf.
CT 8004 (`.12`) ist derselbe Fall und noch ungeprueft.

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

- [x] Der fleet-weite ArgoCD-Auto-Sync-Freeze ist aufgehoben und alle betroffenen
      Applications stehen `Synced/Healthy`. **✅ VOLLSTAENDIG ERFUELLT am 13.09.2026.**
      Beide Haelften: alle 36 Apps `Synced/Healthy`, und alle 36 tragen wieder
      `automated: {prune: true, selfHeal: true}` (PR #165). An diesem Tag erledigt:
      `infra-kite` gesynct (v0.15.0, plus `startupProbe` in #161),
      `app-nextcloud-yealink-phonebook` behoben (#160), `infra-cilium` im Wartungsfenster
      gesynct und der Freeze aus #111 aufgehoben. Nach dem Einschalten sechs Runden lang
      beobachtet: **0 Apps nicht gruen, 0 laufende Syncs** — es lief nichts los, weil der
      Diff null war. Die 11 manuell gepflegten `legacy-proxy`-EndpointSlices sind
      unberuehrt geblieben (`resource.exclusions`).
      **⚠️ Betriebsfolge:** ab jetzt rollt jeder gemergte PR sofort aus, auch Renovate-PRs.
      Die Pruefung liegt vollstaendig im PR.
- [x] nginx-inc besitzt deklarativ und stabil `192.168.2.246` (12.09.2026: per
      `lbipam.cilium.io/ips` am Service gepinnt, DaemonSet 7/7).
- [x] Jeder produktive Traefik-Host existiert als akzeptierter Cluster-Ingress oder
      ist ausdruecklich zur Abschaltung freigegeben (Hostmatrix ohne „entscheiden“).
      **Erfuellt (13.09.2026), maschinell gegengerechnet.** Die 46 Live-Hosts auf `.15`
      (aus `dynamic_conf.yml` und den Docker-Labels) gegen die 56 Hosts der
      Cluster-Ingresses gehalten: **42 haben einen Cluster-Ingress**, die vier uebrigen
      sind entschiedene Faelle — `home.savar.de` (Traefik-Dashboard, entfaellt laut
      Entscheidung 11.09.; der DNS-Name bleibt, weil vier Hosts per CNAME darauf zeigen)
      sowie `imap/pop/smtp.steinba.ch` (liefern keinen Inhalt aus, der Router existiert
      nur fuer den HTTP-01-Bezug des Mailzertifikats; Umbau nach dem Cutover).
      **Kein offenes „entscheiden“ mehr.**
      ⚠️ Beim Nachrechnen nicht `comm` verwenden: Python-`sorted()` und Shell-`sort`
      kollationieren unterschiedlich, `comm` meldet dann „nicht sortiert“ und liefert
      Hosts in beiden Listen gleichzeitig — ein stiller Fehlbefund.
- [x] Jedes SNI hat auf `.246:443` ein gueltiges, `Ready=True`-Zertifikat.
      **Erfuellt (13.09.2026).** Alle **51 TLS-Hosts** aus saemtlichen Ingresses einzeln
      gegen `.246:443` mit SNI abgefragt: in jedem Fall steht der angefragte Name in der
      **SAN-Liste** des tatsaechlich gelieferten Zertifikats — 51 von 51, null
      Auffaelligkeiten. Dazu 36 `Certificate`-Objekte, alle `Ready=True`.
      ⚠️ Nicht gegen den Subject-CN pruefen, der sagt bei Sammelzertifikaten nichts.
- [x] Eine versionierte Host-zu-Solver-Matrix deckt jedes Zertifikat ab; Challenge-Typ
      und Solver stimmen ueberein. Der Catch-all-HTTP01-Solver ist begrenzt oder entfernt.
      **Erfuellt (13.09.2026), gegen den laufenden ClusterIssuer gerechnet.** Vier Solver,
      **keiner ohne Selector** — also kein Catch-all: ClouDNS-Webhook (`jit.services`),
      RFC2136 (9 Zonen), RFC2136 mit `cnameStrategy: Follow` (imcor.de, jonaks.com,
      naturkindergarten-moehringen.de) und HTTP-01, begrenzt auf `horads.de` + `steinba.ch`.
      **Alle 33 ACME-Zertifikate mit ihren 53 DNS-Namen sind eindeutig genau einem Solver
      zugeordnet**, keiner ohne Treffer, keiner mehrdeutig.
      ⚠️ Bei so einer Pruefung fallen drei Zertifikate scheinbar durch das Raster
      (`cert-manager-webhook-cloudns`, `netbird-...-webhook-service`): die stammen von
      **internen CAs**, nicht von Let's Encrypt, und brauchen gar keinen Solver.
- ~~[ ] Die steinba.ch-Mailzertifikatskette laeuft ohne `.15` und wurde einmal
      vollstaendig bis mail05 durchgespielt.~~
      **GESTRICHEN am 13.09.2026 (Entscheidung Ingo: „ja nach dem Cutover“).** Der
      Widerspruch zum Gate ist damit aufgeloest. Der Punkt ist **kein Gate mehr, aber
      Pflichteintrag in der Cutover-Checkliste** (Phase 6) — ab dem Port-80-Schwenk kann
      `.15` nicht mehr erneuern, Ablauf 04.12.2026. **Noch offen: der Verteilmechanismus**
      (Cron auf cfgmgmt01 vs. CronJob im Cluster), siehe „Offene Entscheidungen“ 1b.
- [x] Kein Ingress hat ein `Rejected`-Event. **Erfuellt (13.09.2026): 0 Treffer**,
      weder ueber `--field-selector reason=Rejected` noch als Textsuche in allen Events.
- [x] Alle manuell verwalteten EndpointSlices existieren mit korrekter Adresse, Port
      und Ready-Condition. **Erfuellt (13.09.2026): 11 von 11 in Ordnung** — `auth`
      (.30:8080), `cloud-dev` (.220:443), `cloud-dev-push` (.220:7867), `horads`
      (.240:8080), `imcor` (.21:443), `jitcloud` (.217:443), `mgmt02` (.234:80), `office`
      (.242:9980), `s3` (drei Endpoints .6/.7/.8:7480), `spam` (.230:80), `umdiehand`
      (.20:80); jeweils Port gesetzt und `ready: true`.
      ⚠️ **Was diese Pruefung NICHT leistet:** die `ready`-Bedingung ist bei manuellen
      Slices eine Behauptung, kein Health-Check. `cloud-dev` zeigt auf `.220`, das seit
      dem 11.09. nicht antwortet — die Slice ist trotzdem formal korrekt. Erreichbarkeit
      gehoert in die Anwendungs-Abnahmematrix, nicht hierher.
- [x] Die echte externe Client-IP bleibt ohne Vertrauen in beliebige Client-XFF
      erhalten; ein Spoof-Test ist negativ.
      **Erfuellt (13.09.2026).** Client-IP-Erhalt mit 12 von 12 Anfragen belegt; der
      Spoof-Test negativ: ein Absender ausserhalb `192.168.2.0/24` konnte mit
      gefaelschtem `X-Forwarded-For` keine fremde IP unterschieben. **Einschraenkung:**
      innerhalb des `/24` wird XFF bewusst geglaubt (der Traefik braucht das) — nach dem
      Cutover auf `192.168.2.15/32` verengen, danach entfernen. Details unter Phase 3,
      „Abnahmekriterien“.
- [x] Die vollstaendige Anwendungs-Abnahmematrix ist erfolgreich. **Erfuellt 13.09.2026.**
      Der automatisierbare Teil als Referenzlauf gegen `.15` und nach dem Schwenk erneut
      gegen `.246` — **0 Abweichungen ueber alle 42 Hosts**. Die Tests mit Zugangsdaten
      (Anmeldungen, Upload, WebDAV, Mailversand, Collabora-Dokument) hat Ingo bestaetigt.
- [x] UDM-Rollback und Git-Rollback sind vorbereitet und widersprechen sich nicht bei
      HTTPS-Redirects. **Erfuellt (13.09.2026):** der UniFi-Konfigurationsexport als
      Rollback-Beleg liegt vor, und die beiden Pfade sind unter „Cutover-Reihenfolge und
      Rollback“ ausdruecklich gegeneinander geordnet — Fenster A nur UDM, Fenster B Git
      zuerst. Der Widerspruch, den eine freie Reihenfolge erzeugt haette (Redirect-
      Schleife), ist dort mit Ursache beschrieben.
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
6. **Entscheidung 12.09.2026: `naturkindergarten-moehringen.de` wechselt auf HTTP-01.**
   Statt beim Provider einen CNAME fuer `_acme-challenge` erwirken zu lassen, wird
   `cloud.naturkindergarten-moehringen.de` nach dem Cutover per HTTP-01 ausgestellt.
   **Achtung, die Zone ist bereits im Issuer** — sie steht in Solver 3 (DNS-01
   `cnameStrategy: Follow`) und muss von dort **weg**, sonst greift weiter der
   DNS-01-Pfad, der ohne den fehlenden CNAME nicht funktioniert. Danach: Follow-Solver
   nur noch `imcor.de` + `jonaks.com`, HTTP-01-Solver **drei** Zonen (`horads.de`,
   `steinba.ch`, `naturkindergarten-moehringen.de`). Die Begrenzung bleibt explizit —
   kein Catch-all.

Eine CNAME-Delegation gilt pro angefordertem DNS-Namen. Vor der Solver-Zuordnung
jeder Zone wird die oeffentliche NS-Delegation unmittelbar vor dem Rollout erneut
geprueft.

> **🚫 Harte Vorgabe (Ingo, 12.09.2026): Es wird KEINE weitere Zone auf dns01
> dynamisch gemacht.** Weitere `update-policy`-Zonen brechen **jitix** komplett.
> Braucht ein kuenftiger Name eine noch statische Zone, ist die Antwort ein anderer
> Solver — CNAME-Delegation von `_acme-challenge` auf `acme.jit-creatives.de` oder
> HTTP-01 — **nicht** das Umstellen der Zone. Am 12.09. geprueft: alle neun
> RFC2136-Zonen des ClusterIssuers sind bereits `dynamic: yes`, fuer diesen Cutover
> ist also keine Umstellung mehr noetig.

**Status 12.09.2026: umgesetzt und produktiv.** Alle drei Solver-Klassen sind je durch
eine Staging-Probe im Namespace `cert-manager` belegt (`dns01-staging-cloudns`,
`dns01-staging-rfc2136`, `dns01-staging-rfc2136-follow`). Die Proben bleiben stehen und
dienen als Kanarienvogel: schlaegt eine fehl, ist der Solver kaputt, bevor ein echtes
Zertifikat betroffen ist.

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
`inline-signing` ohne DS. **Erledigt 12.09.2026:** `update-policy { grant cert-manager.
zonesub TXT; }` gesetzt (Backup `.bak-20260912`) und mit `rndc reconfig` aktiviert —
**nicht** `rndc reload`, das laedt Zonenoptionen nicht neu. Zone danach `dynamic: yes`
und `secure: yes`; `expense.porga.de` hat sein Zertifikat gezogen. Folge: die
Zonendatei nur noch ueber `rndc freeze` / editieren / `rndc thaw` anfassen.

### Sonderfall: steinba.ch-Mailzertifikat

Heute: Traefik holt das Zertifikat fuer `imap/pop/smtp.steinba.ch` per HTTP-01
(Router mit toter Senke), ein Cron auf `.15` verteilt es an mail05.

Zielkette:

1. Ein eigener Ingress (oder `Certificate` mit HTTP-01-Solver) fuer die drei Namen
   im Cluster, Solver auf `steinba.ch` begrenzt. Kein ausgelieferter Inhalt auf 443.
2. Die Verteilung an mail05 zieht vom `.15`-Cron auf **denselben Skriptablauf auf
   `cfgmgmt01`, der das Kubernetes-Secret per `kubectl get secret` liest**
   (Entscheidung 13.09.2026; die Variante „CronJob im Cluster mit SSH-Key auf mail05“ ist
   verworfen, weil sie einen neuen Schreibzugriff auf mail05 erfordert haette).
   Das Skript `/usr/local/sbin/steinbach-cert-deploy.sh` (SNI-Map-Erzeugung,
   Hash-Vergleich) wird uebernommen, nur die Quelle aendert sich. Fuer den Zugriff einen
   eigenen ServiceAccount mit Leserecht ausschliesslich auf dieses Secret anlegen, nicht
   das volle Kubeconfig verwenden. Den Cron auf `.15` dabei abschalten, sonst laufen zwei
   Verteiler gegeneinander.
3. Einmal vollstaendig durchspielen (Staging-Zertifikat an mail05 → `openssl s_client
   -starttls imap` pruefen → zurueck auf Produktion), bevor Port 80 umgestellt wird.

Frist: Das aktuelle Zertifikat laeuft am 04.12.2026 ab; Traefik erneuert ab etwa
Anfang November. Wird Port 80 vorher umgestellt, muss die Zielkette schon stehen.

**Entscheidung Ingos 12.09.2026: der Umbau reicht nach dem Cutover.** Damit wird das
Mailzertifikat zum vierten Nachzuegler und faellt in dieselbe Nacharbeit wie
`stream.horads.de` & Co. — nach dem Cutover loest HTTP-01 im Cluster, das Zertifikat
wird dort ausgestellt und von einem neuen Mechanismus an mail05 verteilt.

> **Die Frist bleibt trotzdem scharf, nur an anderer Stelle.** Solange Port 80 noch auf
> `.15` zeigt, erneuert Traefik weiter — die Kette ist also nicht akut gefaehrdet. Kippt
> sie, kippt sie am Cutover-Tag: **ab dem Moment, in dem Port 80 auf `.246` zeigt, kann
> `.15` das Zertifikat nicht mehr erneuern.** Findet der Cutover nach Anfang November
> statt, muss der Umbau im selben Wartungsfenster mit erledigt sein, sonst laeuft das
> Zertifikat am 04.12.2026 ab und Mailclients brechen mit Zertifikatsfehlern ab.
> Aufnehmen in die Cutover-Checkliste, nicht als separate Baustelle fuehren.

### Zertifikate ohne Redirect-Loop ausstellen

Alle bisher HTTP-only betriebenen Ingresses erhalten Issuer und `spec.tls`.
Waehrend der reinen Zertifikatsausstellung bleiben gesetzt:

```yaml
nginx.org/ssl-redirect: "false"
nginx.org/redirect-to-https: "false"
```

Nach erfolgreicher TLS-Abnahme, noch vor dem WAN-Cutover, wird
`nginx.org/redirect-to-https: "true"` aktiviert (entscheidet anhand von
`X-Forwarded-Proto`; Traefik setzt `https`, also kein Loop).

> **⚠️ KORREKTUR 13.09.2026 — hier stand die Reihenfolge falsch herum.** Der Satz lautete:
> „`nginx.org/ssl-redirect` … wird aktiviert, **bevor** Port 80 auf `.246` zeigt.“ Das
> erzeugt genau die Schleife, die dieser Abschnitt verhindern soll: solange `.15` davor
> haengt, terminiert Traefik TLS und proxied **Klartext-HTTP** an `.246:80`; mit
> `ssl-redirect: "true"` sieht nginx dort `$scheme = http`, antwortet mit 301 auf `https`,
> der Client geht wieder ueber `.15` — endlos.
> **Richtig ist: `ssl-redirect` wird erst AKTIVIERT, NACHDEM die UDM auf `.246` zeigt.**
> Reihenfolge und Begruendung stehen unter „Cutover-Reihenfolge und Rollback“.

**Erledigt 12.09.2026**, in zwei Schritten.

> **⚠️ Korrektur eines Fehlschlusses (gleicher Tag).** Der erste Beleg in diesem Abschnitt
> war wertlos: als Zeugen dafuer, dass `"true"` hinter `.15` loop-frei laeuft, hatte ich
> `lists.jitmail.de`, `kimai.savar.de` und `paperless.savar.de` genommen — ausgerechnet
> drei Hosts, deren **Overlay die Annotation auf `"false"` patcht**. Ihre 301/302 waren
> App-Redirects und bewiesen nichts. **Lehre: `grep` in `apps/base/` zeigt nicht den
> gerenderten Stand.** Massgeblich ist das Overlay bzw. `kubectl get ingress -o
> jsonpath='{.metadata.annotations}'`.

**Der tragfaehige Beleg**, nachgeholt nach dem Sync an elf tatsaechlich umgestellten
Hosts ueber `.15`: `s3.savar.de`, `status.jit-creatives.de`, `expense.porga.de`,
`mgmt02.jit-creatives.de`, `spam.savar.de`, `cloud-dev.savar.de`, `office.savar.de`,
`matomo.jit.services` ohne jede Umleitung; `imcor.de` → `/de/`,
`umdiehand.jit-creatives.de` → `/index.php/login`, `auth.savar.de` → Keycloak-Console.
Also ausschliesslich App-Redirects, **kein einziger nginx-Redirect und keine Schleife**.
Der Grund ist die Semantik der Annotation: `redirect-to-https` entscheidet an
`X-Forwarded-Proto` (Traefik setzt `https`), waehrend `ssl-redirect` am Schema
entscheidet — Letzteres wuerde hinter einem TLS-terminierenden Proxy tatsaechlich
endlos umleiten und bleibt deshalb bis zum 443-Cutover `"false"`.

**Schritt 1 (PR #152):** sieben der neun `legacy-proxy`-Ingresses sowie collabora-savar,
gatus-public, expense-tracker und matomo in `apps/base/`.

**Schritt 2 (Folge-PR):** die fuenf Overlays `kimai`, `mailman`, `paperless-ngx`,
`wordpress-1` und `wordpress-2`, die die Annotation per JSON-Patch auf `"false"`
gezogen hatten. Alle fuenf haben seit #149 ein eigenes Zertifikat (`kimai-tls`,
`mailman-tls`, `paperless-tls`, je ein `wordpress-tls`), deren TLS-Hosts die Rules
vollstaendig abdecken. Die Kommentare dort stammten aus der HTTP-only-Ära und
behaupteten noch, TLS und Issuer muessten „wieder ergaenzt" werden — mit korrigiert.

**Diese drei bleiben `"false"`, bis ihre Zertifikate existieren:**

| Ingress | Grund |
|---|---|
| `legacy-proxy/horads` | `stream.horads.de` hat kein Zertifikat (und bewusst keinen Issuer) |
| `legacy-proxy/jitcloud` | enthaelt `cloud.steinba.ch` und `cloud.naturkindergarten-moehringen.de` ohne Zertifikat |
| `roundcube/roundcube-jitmail` | enthaelt `mail.steinba.ch` ohne Zertifikat |

> **Warum das zwingend ist:** Die Annotation wirkt pro Ingress, nicht pro Host. Stuende
> sie hier auf `"true"`, wuerde nach dem Cutover erstens jeder Klartext-Aufruf dieser
> Namen auf ein `https` ohne gueltiges Zertifikat umgeleitet — und zweitens, schwerer
> wiegend, **auch die HTTP-01-Challenge selbst**: cert-manager fragt
> `/.well-known/acme-challenge/…` ueber Port 80 an, der Redirect wuerde sie beantworten
> statt der Token-Datei, und die Ausstellung scheiterte dauerhaft. Reihenfolge ist also:
> Cutover → Zertifikate ziehen → **dann erst** diese drei auf `"true"` nachziehen.

Vor dem NAT-Wechsel muessen beide Pfade funktionieren:

```text
externes HTTPS ueber .15 -> .246:80: kein Redirect-Loop
direktes HTTP zu .246:80: Redirect auf https://<host>/
```

Zuerst `letsencrypt-staging`; Produktion erst, wenn TXT-Create, oeffentliche
Sichtbarkeit und Cleanup fuer jede Solver-Klasse funktionieren.

### Solvermatrix

> **Stand 12.09.2026:** Sofern unten nicht ausdruecklich anders vermerkt, ist jede Zeile
> dieser Matrix **ausgestellt und gegen `.246` per SAN-Pruefung abgenommen**. Die
> Spalte „Status“ gibt den Stand *vor* dem Rollout wieder und bleibt als Historie stehen.
> Ausgenommen sind die vier bewusst ohne Issuer gelassenen Namen: `stream.horads.de`,
> `mail.steinba.ch`, `cloud.steinba.ch` und `cloud.naturkindergarten-moehringen.de`.
> Grund: ein einziger scheiternder Name reisst das gesamte Zertifikat mit.
> **Entscheidung 12.09.2026: alle vier werden direkt nach dem Cutover per HTTP-01
> ausgestellt** — siehe „Nachzuegler-Zertifikate nach dem Cutover“.

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

**✅ ERLEDIGT am 12.09.2026** (PRs #154 und #155). Ingo hat Variante A gewaehlt.

Hartes Gate war dies nicht wegen CrowdSec, sondern wegen der IP-basierten Schutz- und
Drosselmechanismen der Anwendungen (Nextcloud-Brute-Force-Schutz, Roundcube,
`auth.savar.de`): mit SNAT sahen diese alle Clients als eine Adresse.

### Das Problem, gemessen statt vermutet

`externalTrafficPolicy: Local` erhaelt die Quell-IP, ist aber mit Cilium-L2-Announcements
unvertraeglich: **L2 ist nicht endpoint-aware** und kuendigt die VIP auch auf Nodes ohne
lokalen Pod an, die den Verkehr dann verwerfen. Genau das war der Ausfall am 22.07.2026
nach dem wrk3-Rebuild, woraufhin auf `Cluster` zurueckgestellt wurde.

Vor der Umstellung mit einem Kanarienvogel auf `.249` gemessen — dieselben Pods, einziger
Unterschied die Policy:

| Ziel | Ergebnis |
|---|---|
| `.246` (`Cluster`) | 3 von 6 Anfragen kamen als `10.244.6.29` an — die **CiliumInternalIP von wrk4**, also des L2-Announcers |
| `.249` (`Local`) | **6 von 6** mit echter Quell-IP, aus zwei verschiedenen Subnetzen |

Unter `Cluster` wird also genattet, was die announcende Node verlaesst. Die Adresse ist
keine Node-IP, sondern eine Pod-CIDR-Adresse — wer nach `192.168.2.8x` sucht, uebersieht
das SNAT.

### Was umgesetzt wurde

1. **nginx-inc von `kind: deployment` auf `daemonset`** (Chart 2.6.4), mit Toleration fuer
   `node-role.kubernetes.io/control-plane:NoSchedule`. Damit hat **jede** Node, die `.246`
   ankuendigen koennte, einen lokalen Pod — die Bedingung des 22.07.-Ausfalls ist
   beseitigt, nicht umgangen. 7 Pods auf 7 Nodes, je 100m/128Mi.
2. **`.246` per `lbipam.cilium.io/ips` gepinnt.** Vorher ungepinnt im Pool `.246-.249`,
   waehrend die UDM-DNAT-Regel fest darauf zeigt.
3. **`externalTrafficPolicy: Local`** — erst danach, und erst nach dem Kanarienvogel.

**Der entscheidende Vorteil dieser Variante:** alles liegt in `infra-ingress-nginx`
(`Synced/Healthy`). **Kein Cilium-Sync, kein Agenten-Neustart, kein Wartungsfenster** —
Phase 3 ist damit vom Cilium-1.20-Upgrade entkoppelt, das bisher der lange Balken war.

Verworfen wurde **DSR**: es braucht `bpf-lb-mode=dsr`, und bei `routing-mode: tunnel` mit
`tunnel-protocol: vxlan` verlangt DSR Geneve-Dispatch, also eine Umstellung des
Cluster-Tunnelprotokolls — ein ungleich groesserer Eingriff bei gleichem Agenten-Neustart.
Ebenfalls verworfen wurde Variante B (DaemonSet nur auf Workern plus `nodeSelector` in der
`CiliumL2AnnouncementPolicy`): sauberer getrennt, aber die Policy liegt in
`infrastructure/base/cilium/lb-ipam.yaml` und damit im Wartungsfenster.

### Messergebnis nach der Umstellung

| Pruefung | Ergebnis |
|---|---|
| Quell-IP auf `.246` | **12 von 12** echte IP, kein SNAT mehr |
| Ausfall beim Wechsel auf `Local` | **0 von 60** Messpunkten |
| Ausfall beim Wechsel Deployment→DaemonSet | 1 von 90 Messpunkten (~2 s) |
| Regression (8 oeffentliche Hosts) | unveraendert 200 |

### ⚠️ Bedingung, die bestehen bleiben MUSS

nginx laeuft als **DaemonSet auf ALLEN Nodes**, inklusive der tolerierten Control-Plane.
Wer das zurueckdreht — zurueck auf Deployment, ein `nodeSelector`, eine entfernte
Toleration — reisst unter `Local` ein schwarzes Loch auf, weil Cilium-L2 weiterhin nicht
endpoint-aware ist. Der Kommentar in `infrastructure/base/ingress-nginx/values.yaml` sagt
das an Ort und Stelle.

Eine **PodDisruptionBudget waere hier wirkungslos** und wurde bewusst nicht ergaenzt:
`kubectl drain` verlangt bei DaemonSet-Pods `--ignore-daemonsets` und ueberspringt sie
dann, es findet also gar keine Eviction statt, die eine PDB konsultieren koennte. Der
wirksame Hebel ist die Rolling-Update-Strategie (`maxUnavailable: 1`) plus Readiness-Probe.

### Abnahmekriterien

```text
[x] echte externe IPv4 im nginx-Log
[x] keine Uebernahme eines gespooften X-Forwarded-For
[x] funktionierender Wechsel des L2-Lease-Holders
[~] kein Ausfall bei nginx-Pod- oder Node-Neustart  -> ~2 s gemessen, nicht null
[x] korrekter Rueckweg ohne asymmetrisches Routing
```

**Testreihe am 13.09.2026 gefahren** (Ingo hat die Fehlerinjektion freigegeben; Skript
`p3-abnahme.sh`). Ergebnisse:

| Kriterium | Messung | Urteil |
|---|---|---|
| Spoof-XFF, Absender **ausserhalb** `192.168.2.0/24` (`192.168.9.81`, gefaelschtes `X-Forwarded-For: 203.0.113.66`) | nginx protokollierte 3× `192.168.9.81` | **bestanden** — der gefaelschte Wert wird verworfen |
| Spoof-XFF, Absender **innerhalb** (`192.168.2.15` = der Traefik, `X-Forwarded-For: 203.0.113.77`) | nginx protokollierte 3× `203.0.113.77` | **so gewollt** — der vertraute Proxy darf die echte Client-IP durchgeben |
| L2-Lease-Wechsel (Lease geloescht, Neuwahl erzwungen) | Halter `wrk4` → `wrk2`, neuer Halter hatte einen Pod, **0 von 45** Messpunkten ungleich 200 | **bestanden, verlustfrei** |
| Pod-Neustart auf der announcenden Node | **1 von 45** Messpunkten (~2 s), heilte selbst | **nicht null** |

Der L2-Lease-Wechsel ist damit genau das 22.07.-Szenario — und es traegt jetzt ohne einen
einzigen Fehlversuch.

**⚠️ Der Preis von `Local`, gemessen:** stirbt der nginx-Pod auf der **announcenden** Node,
ist `.246` fuer ~2 s tot. Cilium-L2 ist nicht endpoint-aware, schwenkt also nicht weg,
solange die Node selbst lebt. Unter `Cluster` waere das 0 gewesen (der Verkehr waere
weitergeroutet worden). Das ist der bewusst eingekaufte Kompromiss.

**Operative Regel, die daraus folgt — und die den Preis auf null druckt:** Bei geplanten
nginx-Aenderungen **zuerst den L2-Lease von der betroffenen Node wegschieben**
(`kubectl -n kube-system delete lease cilium-l2announce-ingress-nginx-nginx-ingress-controller`,
Neuwahl ist laut Messung verlustfrei), **danach** den Pod neu starten. Wer die Reihenfolge
umdreht, kauft sich pro Node einen Aussetzer ein — bei einem Rolling Update des DaemonSets
also einen, wenn die Reihe die announcende Node trifft.

**Restrisiko beim Spoofing:** vertraut wird das **ganze** `/24`. Jeder Host im LAN kann
damit eine beliebige Client-IP behaupten. Extern ist das wirkungslos (eine Internet-IP
liegt nicht im `/24`), intern aber offen — der Grund, `set-real-ip-from` nach dem Cutover
auf `192.168.2.15/32` zu verengen und danach ganz zu entfernen.

### Zum Spoofing nach dem Cutover

`set-real-ip-from: 192.168.2.0/24` bleibt vorerst. Unter `Cluster` waere das am
Cutover-Tag zur Luecke geworden — der TCP-Peer waere eine Node aus genau diesem `/24`
gewesen, also haette nginx jedem Client sein selbstgesetztes `X-Forwarded-For` geglaubt.
**Unter `Local` schliesst sich das von selbst:** eine Internet-IP liegt nicht im `/24` und
wird damit nicht als vertrauenswuerdiger Proxy behandelt. Verkehr ueber den `.15`-Traefik
kommt weiterhin von `192.168.2.15`, dessen XFF also korrekt uebernommen wird. Haerten
liesse sich das noch auf `192.168.2.15/32`; nach dem Cutover darf niemand mehr XFF setzen.

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

## Cutover-Reihenfolge und Rollback

Erarbeitet am 13.09.2026, alle Aussagen am laufenden System geprueft.

### Was die beiden Redirect-Annotationen wirklich tun

Aus der generierten nginx-Konfiguration ausgelesen, nicht aus der Doku abgeleitet:

| Annotation | erzeugte Regel | feuert wann |
|---|---|---|
| `nginx.org/redirect-to-https` | `if ($http_x_forwarded_proto = 'http') { return 301 https://$host$request_uri; }` | **nur** wenn der Header woertlich `http` ist |
| `nginx.org/ssl-redirect` (Chart-Default `true`, bei uns ueberall `false`) | schema-basiert, aktuell **keine Regel im Cluster** — `$scheme` taucht in der gesamten Konfiguration ausschliesslich als `proxy_set_header X-Forwarded-Proto $scheme` auf | wenn `$scheme = http` |

**Die Folge, die den ganzen Plan bestimmt:** nach dem Schwenk kommt der Verkehr direkt aus
dem Internet und traegt **gar keinen** `X-Forwarded-Proto`. Die Bedingung
`= 'http'` ist damit falsch — **`redirect-to-https` wird am Cutover-Tag wirkungslos.**
Wer nur darauf baut, liefert Port 80 danach unverschluesselt und ohne Weiterleitung aus.
Den Redirect uebernimmt ab dann `ssl-redirect` — und der darf vorher nicht an sein.

Alle Ingresses hoeren uebrigens in **einem** Server-Block auf 80 und 443 gleichzeitig
(`listen 80; listen 443 ssl;`), es gibt keinen separaten Port-80-Block.

### Reihenfolge

| # | Schritt | Warum genau hier |
|---|---|---|
| 0 | UniFi-Konfiguration exportieren | Rollback-Beleg, ist ein eigenes Gate |
| 1 | Snapshot: Gate-Stand, `kubectl -n argocd get application`, `kubectl get certificate -A` | Vergleichsbasis fuer „war das vorher schon so?“ |
| 2 | **UDM: die zwei Regeln fuer 80 und 443 von `192.168.2.15` auf `192.168.2.246`** | der eigentliche Schwenk |
| 3 | Verifizieren: extern Port 80 und 443, SNI-Stichproben, echte Quell-IP im nginx-Log | |
| 4 | Die vier HTTP-01-Zertifikate ziehen (`stream.horads.de`, `mail.steinba.ch`, `cloud.steinba.ch`, `cloud.naturkindergarten-moehringen.de`) | **muss VOR Schritt 5 passieren:** ACME braucht `/.well-known/acme-challenge/` auf Port 80 **unumgeleitet**. Mit aktivem `ssl-redirect` beantwortet nginx die Challenge mit einem 301 und die Ausstellung scheitert dauerhaft |
| 5 | `nginx.org/ssl-redirect: "true"` fleet-weit setzen | erst jetzt — vorher Schleife (siehe Korrektur oben) |
| 6 | `redirect-to-https: "true"` auf `legacy-proxy/horads`, `legacy-proxy/jitcloud`, `roundcube/roundcube-jitmail` nachziehen | erst wenn deren Zertifikate aus Schritt 4 stehen |
| 7 | steinba.ch-Mailzertifikat auf den cfgmgmt01-Cron umbauen, `.15`-Cron abschalten | Frist 04.12.2026 |

**Zwischen Schritt 2 und 5 wird Port 80 unverschluesselt und ohne Weiterleitung
ausgeliefert.** Das ist bewusst so: es ist genau das Fenster, in dem ACME arbeiten kann,
und es ist zugleich das Fenster mit dem billigsten Rollback. Kurz halten, aber nicht
ueberspringen.

### ✅ steinba.ch-Zertifikatskette umgezogen — 13.09.2026

**Die letzte funktionale Abhaengigkeit von `.15` ist aufgeloest.**

Die Zone `steinba.ch` liegt bei hosttech und ist fuer uns nicht aenderbar —
DNS-01 faellt aus, es geht **nur HTTP-01**, und das konnte nur, wer den WAN-Port
80 hat. Bis zum Cutover war das der Traefik auf `.15`; seither zeigt Port 80 auf
`192.168.2.246`. **`.15` konnte damit nicht mehr erneuern** und waere ab etwa
**04.11.2026** still ins Leere gelaufen — Ablauf der drei Namen am 04.12.

### Vorgehen

1. **Staging zuerst** (PR #175): ein Staging-Zertifikat wies nach, dass HTTP-01
   fuer die drei Namen durch den Cluster kommt — **ausgestellt in 41 Sekunden**.
   Damit war der ganze Weg belegt, ohne Produktions-Rate-Limits zu verbrauchen:
   oeffentliches DNS (CNAME auf `mail.jitcreatives.de` → `87.191.135.42`) →
   UDM-DNAT auf `.246` → nginx → HTTP-01-Solver (`dnsZones: [horads.de,
   steinba.ch]`, war bereits vorhanden).
2. **Produktivzertifikat** (PR #176): `Certificate steinbach-mail` im Namespace
   `cert-manager`, Issuer `CN=YR1`, gueltig bis **12.12.2026**.
3. **Zugang fuer cfgmgmt01**: ServiceAccount `steinbach-cert-reader` mit
   **ausschliesslich `get` auf genau dieses eine Secret** — kein `list`, kein
   `watch`, kein anderer Namespace. Nachgeprueft per `kubectl auth can-i`:
   `get secret/steinbach-mail-tls` → yes, `list secret` → no, fremdes Secret → no.
   Langlebiger Token als explizites Secret, weil ServiceAccounts seit Kubernetes
   1.24 keinen mehr von sich aus anlegen.
4. **Auslieferung**: Rolle `jit.steinbach_cert` auf cfgmgmt01, Playbook
   `playbooks/steinbach_cert.yml`, taeglich 04:47. Liest das Secret per `curl`
   ueber die API (`kubectl` ist dort nicht installiert und wird auch nicht
   gebraucht) und rollt nach mail05 aus — dieselben Dateien und derselbe Reload
   wie zuvor.
5. **Erst danach** den Cron auf `.15` abgeschaltet.

### Verifiziert

Alle vier Dienste liefern das neue Zertifikat: **993 (IMAP), 995 (POP3),
465 (SMTPS), 587 (STARTTLS)**, jeweils `notAfter=Dec 12 15:40:02 2026`. Das
Hauptzertifikat `mail.jit-creatives.de` ist unberuehrt. Der zweite Lauf meldet
`unveraendert` — der Cron startet also nicht taeglich ohne Grund Dienste neu.
Die Rolle ist idempotent (`changed=0` im zweiten Lauf). Der Stand von vorher
liegt als Sicherung unter `/root/steinbach-cert-backup-20260913` auf mail05.

### Zwei Sicherungen, die die alte Fassung nicht hatte

Das Skript **weigert sich, ein Staging-Zertifikat auszurollen**, und prueft, dass
**Schluessel und Zertifikat zusammengehoeren** (Vergleich der oeffentlichen
Schluessel). Beides wuerde sonst still TLS auf dem Mailserver brechen.

### Wichtig beim Nachbauen

- In der `sni_map` ist der **WERT das base64-kodierte Schluesselmaterial, kein
  Pfad** — ein Pfad quittiert Postfix mit `malformed BASE64 value` und faellt
  still aufs Standardzertifikat zurueck.
- `combined.pem` ist **privkey vor fullchain**. Postfix will fuer SNI eine Datei
  mit beidem, Dovecot dagegen beides getrennt — deshalb wird beides ausgeliefert.
- **Token und CA stehen bewusst nicht im Repo**, der Token ist eine
  Cluster-Berechtigung. Die Rolle prueft nur ihr Vorhandensein und nennt im
  `fail_msg`, wie man sie holt.

### ⚠️ Eigener Fehler beim Abschalten

Beim Deaktivieren des alten Cron ist mein `sed` am Trennzeichen gescheitert
(`#` war zugleich Delimiter und Inhalt) — und die kaputte Ausgabe ging trotzdem
in `crontab -`, wodurch die crontab auf `.15` kurz leer war. Dort stand nur
dieser eine Job, es ging nichts anderes verloren, und der Zustand wurde
bewusst dokumentiert wiederhergestellt. **Merkregel: neue crontab erst in eine
Datei schreiben, pruefen, dann `crontab <datei>` — niemals eine Pipeline
ungeprueft in `crontab -` laufen lassen.**

## Rollback

Es gibt **zwei Fenster mit unterschiedlichem Rueckweg**. Welches gilt, entscheidet allein
die Frage: steht `ssl-redirect` schon auf `true`?

**Fenster A — Schritte 2 bis 4, `ssl-redirect` noch `false`:**

> **Rollback = die zwei UDM-Regeln zurueck auf `192.168.2.15`. Sonst nichts.**

Eine einzige Aenderung, sofort wirksam, **ohne Git und ohne ArgoCD**. Die Cluster-Seite ist
in diesem Fenster exakt so konfiguriert wie vor dem Cutover: `redirect-to-https` feuert
hinter Traefik korrekt, `ssl-redirect` ist aus. **Deshalb Schritt 5 so lange wie moeglich
hinauszoegern** — je laenger Fenster A dauert, desto billiger bleibt der Rueckweg.

**Fenster B — ab Schritt 5, `ssl-redirect` steht auf `true`:**

Rollback **in dieser Reihenfolge, nicht anders**:

1. **Git zuerst:** Revert des `ssl-redirect`-PRs. ArgoCD hat seit 13.09.2026 `automated`
   mit `selfHeal` — das rollt **von selbst binnen ~3 Minuten** aus, ein manueller Sync ist
   weder noetig noch moeglich zu ueberspringen.
2. **Warten und im Cluster nachsehen**, dass die Annotation wirklich wieder `false` ist:
   `kubectl get ingress -A -o json | grep ssl-redirect`. Nicht auf den Merge vertrauen,
   auf den Ist-Zustand.
3. **Erst dann** die zwei UDM-Regeln zurueck auf `.15`.

> **Die umgekehrte Reihenfolge erzeugt die Schleife.** UDM zurueck auf `.15`, waehrend
> `ssl-redirect` noch `true` ist: Traefik terminiert TLS → proxied Klartext an `.246:80`
> → nginx sieht `$scheme = http` → 301 auf `https` → Traefik → endlos. Alle Hosts
> gleichzeitig tot, und der Fehler sieht aus wie ein Zertifikatsproblem.

**Ein Git-Rollback allein, ohne UDM-Aenderung, ist in beiden Fenstern gefahrlos.**

### Was ein Rollback NICHT zurueckholt

- **Ausgestellte Zertifikate bleiben.** Harmlos, sie stoeren nicht.
- **Die vier HTTP-01-Zertifikate aus Schritt 4 lassen sich nach dem Rollback nicht mehr
  erneuern**, weil Port 80 wieder bei Traefik liegt. Sie halten 90 Tage — ein zweiter
  Cutover-Versuch sollte davor stattfinden.
- **Ist Schritt 7 schon gelaufen**, muss beim Rollback der `.15`-Cron fuer das
  steinba.ch-Mailzertifikat wieder aktiviert werden, sonst erneuert ihn niemand.
- **Der UniFi-Controller ueberschreibt SSH-Aenderungen.** Der Rollback muss im Controller
  passieren, nicht per `iptables` auf der UDM.

### Vorher festlegen, nicht im Ernstfall entscheiden

- **Wer darf den Rollback ausloesen** und ab welchem Symptom?
- **Wie lange wird beobachtet**, bevor Schritt 5 kommt? (Vorschlag: mindestens bis die vier
  Zertifikate stehen und eine volle Stunde ohne Auffaelligkeit vergangen ist.)
- **Womit wird gemessen?** Die Probe aus dem Cilium-Fenster taugt unveraendert:
  1-s-Aufloesung auf `.246` und `.247`, dazu die Gatus-Instanzen — die sind seit dem
  13.09. aussagekraeftig, ein roter Punkt bedeutet wieder etwas.

## Anwendungs-Abnahmematrix (externe Hosts)

Erarbeitet am 13.09.2026. **Geltungsbereich: die 42 externen Hosts in 21 Ingresses**
(`*.jit.services` bleibt aussen vor — intern und nicht Teil des WAN-Cutovers).

**Prioritaeten (Entscheidung Ingo):** Prio 1 sind **Nextcloud, Roundcube und
`stream.horads.de`** — bricht dort etwas und ist es nach **20 Minuten** weder verstanden
noch behoben, wird zurueckgerollt. Alles Uebrige hat Zeit und wird im Betrieb nachgezogen.

> **Warum ein 200 nicht reicht.** Bisher ist geprueft, dass jeder Host antwortet und das
> richtige Zertifikat liefert. Das beweist nicht, dass der Dienst funktioniert. Beispiel
> aus der Vorbereitung: `legacy-proxy/cloud-dev` hat eine formal einwandfreie
> EndpointSlice mit `ready: true` — und zeigt auf ein `.220`, das seit dem 11.09. tot ist.
> Genau solche Faelle findet nur ein funktionaler Test.

### Prio 1 — diese drei entscheiden ueber Rollback

| # | Host(s) | Test | Erwartung |
|---|---|---|---|
| 1.1 | `stream.horads.de` | `curl -s --max-time 30 -o /dev/null -w '%{size_download}' https://stream.horads.de/horads` | **> 1.000.000 Bytes**. Gemessen am 13.09.: 312 kB in 8 s (~312 kbit/s), Mount `/horads`, `audio/mpeg` |
| 1.2 | `stream.horads.de` | `curl -s https://stream.horads.de/status-json.xsl` | JSON lesbar, Hoererzahl plausibel. Am 13.09.: **12 Hoerer live** — ein abbrechender Handshake wirft sie alle raus |
| 1.3 | `stream.horads.de` | Dauerverbindung 60 s ohne Abbruch | `proxy-buffering: false` und `proxy-read-timeout: 3600s` muessen greifen; ein Abbruch nach ~60 s deutet auf verlorene Annotationen |
| 1.4 | Nextcloud: `cloud.savar.de`, `jit.cloud`, `cloud.daec-berlin.de`, `cloud.steinba.ch`, `cloud.naturkindergarten-moehringen.de` | `GET /status.php` | `installed:true`, `maintenance:false`. Ueber `.246` am 13.09. bereits verifiziert (Nextcloud 33.0.7) |
| 1.5 | Nextcloud | Anmeldung im Browser, dann eine Datei hoch- und wieder herunterladen | Upload ohne Groessenfehler (`client-max-body-size: 0`) |
| 1.6 | Nextcloud | `PROPFIND /remote.php/dav/files/<user>/` mit Zugangsdaten | **207 Multi-Status**. Das ist der Test, den Sync-Clients wirklich fahren |
| 1.7 | Nextcloud | Client-IP im Nextcloud-Log pruefen | echte Absender-IP, nicht die einer Node. `trusted_proxies` steht auf `192.168.2.0/24` und deckt die Nodes `.81`–`.87` ab (13.09. geprueft) |
| 1.8 | Roundcube: `roundcube.savar.de`, `mail.steinba.ch`, `webmail01.jit-creatives.de`, `jitmail.de`, `www.jitmail.de`, `webmail.daec-berlin.de` | Anmeldung, Ordnerliste oeffnen | IMAP-Verbindung steht, Ordner werden gelistet |
| 1.9 | Roundcube | Testmail mit Anhang (~10 MB) senden | Versand erfolgreich (`client-max-body-size: 25m`) |

### Prio 2 — darf nach dem Cutover nachgezogen werden

| Host(s) | Test | Worauf es ankommt |
|---|---|---|
| `office.savar.de` (Collabora) | Dokument in Nextcloud oeffnen und tippen | **WebSocket-Upgrade** — ein 200 auf `/` beweist gar nichts. Die Annotation `websocket-services` muss exakt den Servicenamen tragen |
| `auth.savar.de`, `auth2.savar.de` (Keycloak) | Anmeldung an der Admin-Konsole | Die Brute-Force-Sperre sieht ab jetzt **echte** Client-IPs statt einer Sammeladresse |
| `imcor.de`, `www.imcor.de`, `db.imcor.de`, `config.imcor.de`, `jonaks.com`, `www.jonaks.com` | Startseite | Re-Encrypt zu `.21:443` (`ssl-services`). `jonaks.com` antwortet **403 — vorbestehend**, kommt vom Apache auf `.21` selbst |
| `www.jit-creatives.de`, `mgmt02.jit-creatives.de`, `www.jitcreatives.de`, `ftp.jit-creatives.de` | Startseite | Backend `.234:80` |
| `s3.savar.de`, `s3.jit-creatives.de` | Bucket-Listing oder `HEAD` auf ein Objekt | Ceph RGW mit **drei** Endpoints (`.6`/`.7`/`.8:7480`) — alle drei muessen bedient werden |
| `spam.savar.de` | rspamd-Oberflaeche | Backend `.230:80` |
| `umdiehand.jit-creatives.de`, `gesinefranze.jit-creatives.de` | Startseite | Backend `.20:80` |
| `lists.jitmail.de` | Postorius oeffnen, eine Liste ansehen, Archiv aufrufen | **Der LMTP-Eingang auf `.247:8024` ist vom Cutover nicht betroffen** und braucht keinen Test |
| `paperless.savar.de` | Anmeldung, ein Dokument oeffnen | |
| `phpmyadmin.jit-creatives.de`, `phpmyadmin.savar.de` | Anmeldung | |
| `kimai.savar.de` | Anmeldung, eine Zeitbuchung oeffnen | |
| `jugendbeauftragter-halbe.de` + `www.`, `gemeinsam-fuer-halbe.de` + `www.` | Startseite **und `/wp-admin/`** | wp-admin ist der klassische Schleifen-Kandidat: WordPress leitet dort anhand von `$_SERVER['HTTPS']` um, das per `WORDPRESS_CONFIG_EXTRA` fest auf `on` steht |
| `expense.porga.de` | Anmeldung | **401 auf `/` ist erwartet**, kein Fehler |
| `status.jit-creatives.de` | Statusseite oeffnen | Muss nach dem Cutover gruen sein — sie ist danach das Messmittel |
| `cloud-dev.savar.de` | — | **502 ist erwartet und KEIN Regressionsbefund**: Backend `nc01-dev` (`.220`) antwortet seit dem 11.09. nicht. Entscheidung vom 11.09.: Host bleibt |

### Vor dem Cutover einmal als Referenz aufnehmen

Damit „war das vorher schon so?" im Fenster nicht diskutiert werden muss: **dieselbe Matrix
einmal ueber `.15` durchfahren und die Ergebnisse festhalten.** Ohne diese Referenz kostet
jeder vorbestehende 401/403/502 im Fenster unnoetige Minuten.

### Referenzlauf vom 13.09.2026 (Zustand VOR dem Cutover)

Ueber den aktuellen Pfad (`.15`) gemessen, damit im Fenster nicht diskutiert werden muss,
ob ein Wert vorher schon so war.

**Alle 42 externen Hosts:** HTTP erreichbar, `ssl_verify_result=0`, angefragter Name
jeweils **im SAN** des gelieferten Zertifikats. Kein Zertifikat laeuft im Cutover-Fenster
ab (frueheste Ablaeufe: 20.–31.10.2026).

**Die drei Abweichungen sind vorbestehend — kein Rollback-Grund:**

| Host | Wert | Ursache |
|---|---|---|
| `jonaks.com` | **403** | kommt vom Apache auf `.21` selbst, nicht vom Proxy |
| `expense.porga.de` | **401** | Authentifizierung, so gewollt |
| `cloud-dev.savar.de` | **502** | Backend `nc01-dev` (`.220`) antwortet seit dem 11.09. nicht |

**Prio 1 — die Sollwerte fuer nachher:**

| Prueflinge | Referenzwert 13.09.2026 |
|---|---|
| `stream.horads.de`, Mount `/horads` | **1.017.800 Bytes in 30 s**, **12 Hoerer** gleichzeitig |
| Nextcloud, alle fuenf Hosts, `/status.php` | `installed=true`, `maintenance=false`, **Version 33.0.7** |
| Roundcube (`roundcube.savar.de`, `mail.steinba.ch`, `jitmail.de`) | Titel `J.I.T. - Mail :: Welcome to J.I.T. - Mail` |

**Prio 2 — Referenzwerte:**

| Pruefling | Referenzwert |
|---|---|
| `office.savar.de` `/hosting/discovery` und `/hosting/capabilities` | je **200**, `capabilities` liefert JSON mit `convert-to available` |
| `lists.jitmail.de` | 200, landet auf `/postorius/lists/`, **7.661 Bytes** |
| `paperless.savar.de` | 200, landet auf `/accounts/login/`, **9.007 Bytes** |
| `kimai.savar.de` | Titel `Kimai` |
| `phpmyadmin.savar.de` | Titel `phpMyAdmin` |
| `jugendbeauftragter-halbe.de` und `gemeinsam-fuer-halbe.de`, je `/wp-admin/` | **200 nach genau 1 Umleitung** — keine Schleife |
| `s3.savar.de` | 200 |

> **⚠️ Was dieser Referenzlauf NICHT abdeckt** — und was im Fenster von Hand geprueft
> werden muss, weil es Zugangsdaten braucht: Anmeldung bei Nextcloud, Roundcube, Keycloak,
> Paperless, Kimai und phpMyAdmin; Datei-Upload und WebDAV-`PROPFIND` bei Nextcloud;
> Mailversand mit Anhang bei Roundcube; und der **echte WebSocket-Test bei Collabora**.
> Letzterer geht nur aus einer Dokumentsitzung heraus — ein synthetisches Upgrade auf
> `/cool/adminws` liefert erwartungsgemaess **403**, weil der Pfad Authentifizierung
> verlangt, und beweist damit nichts.

## Rollback: Ausloesekriterien

Festgelegt am 13.09.2026.

**Sofort zurueck, ohne Diskussion:**

- **Redirect-Schleife** auf irgendeinem Host — eindeutiges Symptom, eindeutige Ursache
- **Mehr als ein unabhaengiges Problem gleichzeitig** — parallele Diagnose im Fenster geht schief
- **Anmeldung kaputt** bei Nextcloud, Roundcube oder Keycloak
- **`stream.horads.de` liefert keine Daten mehr** (Prio 1, und der Ausfall ist fuer Hoerer sofort spuerbar)

**Zeitbox:**

- **Ein einzelnes Prio-1-Problem, das nach 20 Minuten weder verstanden noch behoben ist**
  → zurueck, in Ruhe analysieren. Der teuerste Fehler waere, im Fenster zu forschen.
- **Prio-2-Dienste loesen keinen Rollback aus.** Sie werden im Betrieb nachgezogen.

**Der nicht offensichtliche Haltepunkt:**

- Solange **PR #169 (`ssl-redirect`) nicht gemergt** ist, kostet der Rueckweg **eine einzige
  UDM-Aenderung**. Danach sind es zwei Schritte mit Wartezeit auf ArgoCD. **Vor diesem
  Merge deshalb ein bewusster Halt:** ist zu diesem Zeitpunkt irgendetwas unklar, zurueck,
  solange es billig ist.

**Ausdruecklich KEIN Rollback-Grund:**

- `expense.porga.de` antwortet mit 401, `jonaks.com` mit 403, `cloud-dev.savar.de` mit 502
  — alle drei vorbestehend
- GitLabs HTTP 500 — vorbestehend und unabhaengig vom Cutover
- Langsame erste Antworten durch kalte Caches
- Abgerissene Langzeitverbindungen im Moment des NAT-Wechsels: bestehende Sessions laufen
  gegen `.15` weiter, bis sie ablaufen. Das ist erwartetes Verhalten, kein Defekt.

## ✅ Cutover vollzogen am 13.09.2026

Die UDM zeigt fuer 80 und 443 auf `192.168.2.246`. Ablauf und Messwerte:

| Schritt | Ergebnis |
|---|---|
| Vorher-Schnappschuss | 36 Apps gruen, 36 Zertifikate Ready, nginx 7/7, **42 von 42 externen Hosts hatten auf `.246` bereits ein Zertifikat mit ihrem Namen im SAN** |
| UDM-Schwenk (~10:44:50 UTC) | zwei Controller-Eintraege, Ziel `.15` → `.246` |
| Messung, 600 Punkte ueber 25 min | **7 Abweichungen**, davon 2 durch einen eigenen Testlauf verursacht |
| `stream.horads.de` | **0 Ausfaelle** — Prio 1 erfuellt |
| Nextcloud | **0 Ausfaelle** |
| `roundcube.savar.de` | **31 s**, danach von selbst zurueck |
| Nachher-Lauf gegen die Referenz | **0 Abweichungen ueber alle 42 Hosts** |
| `stream.horads.de` Durchsatz | **1.017.800 Bytes in 30 s** — exakt der Referenzwert |

**Dass der Stream durchlief, ist das Ergebnis des Vorladens.** Ohne die drei vorgeladenen
Zertifikate haette nginx fuer diese Namen gar keins geliefert und der TLS-Handshake waere
abgebrochen — zum Messzeitpunkt hingen 12 Hoerer am Stream.

### Echte Client-IP: unter realen Bedingungen bewiesen

Von edge01 (`88.198.107.9`, echter Internet-Absender) getestet:

| Test | nginx protokolliert |
|---|---|
| normale Anfrage | **88.198.107.9** |
| mit gefaelschtem `X-Forwarded-For: 203.0.113.99` | **88.198.107.9** — die Faelschung wird verworfen |

Damit ist Phase 3 nicht nur im Labor, sondern im Betrieb belegt.

### ⚠️ Zwei Fehler, die dabei ans Licht kamen

**1. HTTP-01 funktioniert fuer diese drei Ingresses noch nicht — `edit-in-place` fehlt.**
Ein Staging-Testzertifikat fuer `stream.horads.de` scheiterte mit
`wrong status code '404', expected '200'`. Ursache: cert-manager legt einen eigenen
Solver-Ingress an, der denselben Host beansprucht — nginx-inc lehnt ihn mit
`All hosts are taken by other resources` ab, und die Challenge landet beim Icecast-Backend.
**Der Fix ist die Annotation `acme.cert-manager.io/http01-edit-in-place: "true"`**, die im
Plan zwar erwaehnt, aber auf diesen Ingresses nie gesetzt war.

**2. Der Wechsel auf cert-manager ist nicht so einfach wie gedacht — ArgoCD und
cert-manager streiten sich um dasselbe Secret.** Traegt der Ingress die
cert-manager-Annotation, schreibt cert-manager in genau das Secret, das der
ksops-Generator aus Git erzeugt. Mit `selfHeal` setzt ArgoCD das binnen ~3 Minuten zurueck,
cert-manager stellt neu aus, und so fort. Ein *neuer* Secret-Name vermeidet das, reisst
aber zwischen Sync und Ausstellung genau die Luecke auf, die das Vorladen verhindern
sollte.

**Deshalb ist Schritt 4 bewusst verschoben.** Die vorgeladenen Zertifikate laufen bis
**24.10. / 27.10. / 30.11.2026** — kein Zeitdruck. Und `ssl-redirect` bleibt auf den drei
Preload-Ingresses `"false"`, blockiert die spaetere Umstellung also nicht. Sauber ist ein
eigenes ruhiges Fenster, pro Host, mit dem `edit-in-place`-Fix.

### ⚠️ Ein Fehler in der PR-Reihenfolge, korrigiert mit #173

PR #169 entstand als Draft, **bevor** #170 die zertifikatslosen Namen in eigene
Preload-Ingresses ausgelagert hat — und wurde danach nicht mehr gegen den neuen Stand
geprueft. Dadurch standen `legacy-proxy/jitcloud` und `roundcube/roundcube-jitmail` ohne
Not weiter auf `"false"`, obwohl sie nur noch Hosts **mit** Zertifikat trugen. Acht Hosts
lieferten Port 80 rund 15 Minuten lang unverschluesselt und ohne Weiterleitung aus.
Aufgefallen ist es daran, dass `roundcube.savar.de` auf HTTP schlicht mit **200** statt
mit einer Umleitung antwortete.

> **Lehre: ein vorbereiteter Draft ist kein eingefrorener Zustand.** Aendert sich zwischen
> Vorbereitung und Merge die Struktur — und #170 hat genau das getan —, gehoert der Draft
> erneut gegen den aktuellen Stand gerendert. Ein `kustomize build`-Vergleich haette es in
> Sekunden gezeigt.

### Endstand nach dem Cutover

`ssl-redirect`: **31 Ingresses `true`, 3 `false`** (die Preload-Ingresses `horads`,
`jitcloud-preload`, `roundcube-jitmail-preload`). Schleifentest: 1–2 Umleitungen, alle
enden bei 200. 36 Apps gruen, 36 Zertifikate Ready, nginx 7/7 mit **0 Neustarts**.

### Was jetzt noch offen ist

1. **Die vier Namen auf cert-manager umstellen** (mit `edit-in-place`, eigenes Fenster,
   vor dem 24.10.). Danach Preload-Secrets, Generatoren und die beiden Preload-Ingresses
   entfernen — die Hosts wandern zurueck in `jitcloud` bzw. `roundcube-jitmail`.
2. **steinba.ch-Mailzertifikat** auf den cfgmgmt01-Cron umbauen, `.15`-Cron abschalten.
   Ablauf 04.12.2026, ab jetzt kann `.15` nicht mehr erneuern.
3. **`.15` beobachten und abschalten** (Phasen 7 und 8).
4. Nach dem Abschalten: `set-real-ip-from` auf `192.168.2.15/32` verengen, danach ganz
   entfernen.

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
3. ~~steinba.ch-Cron auf `.15` deaktivieren~~ — **erledigt 13.09.2026**, siehe
   „steinba.ch-Zertifikatskette umgezogen" weiter unten.
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
| 12 | Potsdam-DR-Edge aktualisieren oder aufgeben? | erledigt 12.09.: aktualisiert und ausgerollt |
