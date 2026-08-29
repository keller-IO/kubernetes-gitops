# Matomo — Inbetriebnahme und Einbindung

Stand: 2026-08-29

Selbst gehostete Web-Analyse für `www.jit-creatives.de`. Ziel war, den
Bestelltrichter der Nextcloud-Seite überhaupt erst messbar zu machen — bis dahin
gab es weder Analytics noch ein Zielereignis, jede Änderung an der Seite war also
Geschmackssache statt Entscheidung.

## Architektur und warum sie so aussieht

```
Besucher → www.jit-creatives.de/stats/matomo.php     (first-party)
             │  nginx auf mgmt02, proxy_pass
             ↓
           Cluster-LB 192.168.2.246 (HTTP, Host: matomo.jit.services)
             ↓
           Service matomo → Pod matomo:5.13.0-apache
                              └─ MariaDB matomo-mariadb (Operator)

Auswertung → https://matomo.jit.services   (nur intern, via WireGuard)
```

Zwei Entscheidungen, die den Rest erklären:

**Der Tracker läuft first-party.** Statt einer eigenen öffentlichen Subdomain
(`analytics.jit-creatives.de`) wird der Tracker unter dem Pfad `/stats/` der
bestehenden Domain durchgereicht. Das spart einen DNS-Eintrag *und* ein
Zertifikat am `.15`-Traefik, und es fällt Adblockern kaum auf — ein Skript von
der eigenen Domain wird deutlich seltener blockiert als eines von einer als
Analytics erkennbaren Adresse. Die Messung wird dadurch schlicht vollständiger.

**Die Oberfläche bleibt intern.** `matomo.jit.services` ist nur über WireGuard
erreichbar. Besucherdaten liegen damit nicht auf einer öffentlich adressierbaren
Anwendung, und es gibt keine öffentliche Login-Maske, die jemand ausprobieren
könnte.

## Datenschutz

Es wird cookielos gemessen, mit gekürzter IP und respektiertem DoNotTrack. Nach
überwiegender Auffassung ist dafür in Deutschland **kein Einwilligungsbanner**
nötig. Das ist eine Einschätzung, keine Rechtsberatung — im Zweifel prüfen lassen.

Wichtig zu wissen: die Einstellungen liegen an **zwei** Stellen, und nur eine
davon ist versioniert.

| Einstellung | Wo | Versioniert? |
|---|---|---|
| Keine Cookies (`disableCookies`) | Tracking-Snippet | ja, im Django-Template |
| DoNotTrack beachten (`setDoNotTrack`) | Tracking-Snippet | ja, im Django-Template |
| Echte Besucher-IP erkennen (`proxy_client_headers`) | `configmap.yaml` | ja |
| Keine Drittanbieter-Cookies | `configmap.yaml` | ja |
| Kein websiteübergreifendes Fingerprinting | `configmap.yaml` | ja |
| **IP-Maskierung 2 Bytes** | Datenbank (PrivacyManager) | **nein — manuell** |
| **DoNotTrack serverseitig** | Datenbank (PrivacyManager) | **nein — manuell** |
| **Rohdaten-Löschung nach 90 Tagen** | Datenbank (PrivacyManager) | **nein — manuell** |

Die drei unteren sind PrivacyManager-Optionen und lassen sich **nicht** über
`config.ini.php` vorgeben — Matomo speichert sie in der `option`-Tabelle. Sie
müssen einmalig in der Oberfläche gesetzt werden (Schritt 3 unten). Deshalb
erzwingt das Snippet cookieless und DNT zusätzlich clientseitig: dieser Teil kann
nicht vergessen werden, weil er im Git-verwalteten Template steht.

## Inbetriebnahme

### 1. Ausrollen

Der Merge des Branches genügt — die ArgoCD-ApplicationSet legt für jedes
Verzeichnis unter `apps/overlays/main/*` automatisch eine Application an
(`app-matomo`, Namespace `matomo`, `selfHeal` + `prune` aktiv).

```bash
kubectl -n matomo get pods,mariadb,ingress
```

Der Erststart dauert: Matomo entpackt seine Dateien auf das Ceph-Volume. Die
`startupProbe` gibt dafür bis zu 10 Minuten.

### 2. Installations-Assistent

```bash
# Von einem Rechner im WireGuard-Netz:
open https://matomo.jit.services
```

- Datenbank: Host `matomo-mariadb`, Name `matomo`, Benutzer `matomo`.
  Das Passwort steht in `matomo-secret` (`mariadb-password`).
- Erste Website anlegen: Name `jit-creatives.de`, URL `https://www.jit-creatives.de`.
- Die **Site-ID** merken (in aller Regel `1`) — sie wird im Snippet gebraucht.

Das vom Assistenten angebotene Tracking-Snippet wird **nicht** übernommen; es
enthält weder `disableCookies` noch den first-party-Pfad. Stattdessen Schritt 4.

### 3. Datenschutz-Einstellungen setzen (einmalig, nicht versioniert)

*Administration → Datenschutz → Anonymisierung der Daten:*

- IP-Adressen anonymisieren: **an**, Maskierung **2 Bytes**
- Auch für Berichte die anonymisierte IP verwenden: **an**
- DoNotTrack-Einstellung respektieren: **an**
- UserId anonymisieren: **an**

*Administration → Datenschutz → Alte Daten löschen:*

- Alte Rohdaten löschen: **an**, älter als **90 Tage**
- Alte aggregierte Berichte behalten (die enthalten keine Personenbezüge mehr)

Prüfen lässt sich das anschließend unter *Besucher → Besucherprotokoll*: dort
darf keine vollständige IP mehr stehen, sondern nur noch `87.191.0.0`.

### 4. Tracker einbinden

Zwei Teile, beide in Git:

**a) nginx auf mgmt02** — reicht `/stats/` an den Cluster durch:

```nginx
location /stats/ {
    proxy_pass         http://192.168.2.246/;
    proxy_set_header   Host              matomo.jit.services;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto https;
    proxy_set_header   X-Forwarded-Host  www.jit-creatives.de;
}
```

Ohne `X-Forwarded-For` sähe Matomo bei jedem Besuch die IP des Proxys statt die
des Besuchers — die Statistik wäre wertlos und die IP-Anonymisierung liefe ins
Leere. Die Gegenstelle dazu steht in `configmap.yaml` (`proxy_client_headers`).

**b) Snippet im Django-Template** (`newdesign/templates/head.django.html`):

```html
<script>
  var _paq = window._paq = window._paq || [];
  _paq.push(['disableCookies']);          // cookielos - kein Einwilligungsbanner noetig
  _paq.push(['setDoNotTrack', true]);     // DoNotTrack des Browsers respektieren
  _paq.push(['trackPageView']);
  _paq.push(['enableLinkTracking']);
  (function() {
    var u = "/stats/";                    // first-party, nicht matomo.jit.services
    _paq.push(['setTrackerUrl', u + 'matomo.php']);
    _paq.push(['setSiteId', '1']);
    var d = document, g = d.createElement('script'), s = d.getElementsByTagName('script')[0];
    g.async = true; g.src = u + 'matomo.js'; s.parentNode.insertBefore(g, s);
  })();
</script>
```

Reihenfolge beachten: `disableCookies` muss **vor** `trackPageView` stehen, sonst
wird beim ersten Aufruf noch ein Cookie gesetzt.

### 5. Ziel für den Bestelltrichter anlegen

Der eigentliche Zweck. *Ziele → Neues Ziel:*

- Name: `Nextcloud-Bestellung abgeschickt`
- Auslöser: Besuch einer bestimmten URL, **enthält** `/cloud/order/` und `success`

Damit wird endlich messbar, wie viele Menschen `/cloud/` öffnen und wie viele
davon bestellen. **Vor** weiteren Änderungen an der Seite zwei Wochen Baseline
sammeln, sonst lässt sich hinterher nicht sagen, was gewirkt hat.

## Betrieb

- **Backup:** täglich 02:30 als logischer Dump nach Garage-S3
  (`backups/mariadb-matomo`), 30 Tage Aufbewahrung. Versetzt zu kimai (02:00).
- **Archivierung:** läuft browser-getriggert (Matomo-Default). Für diese
  Besuchermenge ausreichend. Ein `core:archive`-CronJob wäre sauberer, scheitert
  aber am RWO-Volume (der CronJob-Pod käme auf einen anderen Node → Multi-Attach)
  und bräuchte zuerst ein API-Token. Offen, siehe PRODUCTION-READINESS.
- **Opt-out:** Matomo liefert unter *Datenschutz → Nutzer-Opt-out* einen iFrame.
  Der gehört auf die Datenschutzseite — auch beim cookielosen Betrieb, weil er
  die einzige Möglichkeit für Besucher ist, der Zählung aktiv zu widersprechen.

## Fallstricke

- **Ping auf `192.168.2.246` schlägt immer fehl.** Cilium-LB-IPs antworten nicht
  auf ICMP. Nur Service-Ports testen, sonst sucht man an der falschen Stelle.
- **HTTPS zum Cluster-LB nur mit passendem Zertifikat.** `curl` gegen `.246` mit
  einem Hostnamen ohne Zertifikat liefert `tlsv1 unrecognized name`. Deshalb
  proxiert mgmt02 bewusst über **HTTP**; der Ingress hat dafür
  `redirect-to-https: "false"`.
- **Kein `force_ssl = 1`** in der Matomo-Konfiguration. In Verbindung mit dem
  HTTP-Proxypfad ergäbe das eine Weiterleitungsschleife.
