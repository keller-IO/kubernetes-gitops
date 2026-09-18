# Flurfunk-Onboarding: drei unabhängige Fehler in der DNS/TLS-Kette

## Symptom

Nach erfolgreichem `app-flurfunk`-Sync (Pod `Running`, PVC `Bound`, Ingress
angelegt) blieb `Certificate flurfunk-tls` über zwei Stunden auf
`READY: False`. Drei voneinander unabhängige Ursachen mussten nacheinander
behoben werden, bevor `https://app.wohngut.net` erreichbar war.

## Ursache 1 — named.conf-Stanza in der Zonen-Datendatei

`/etc/bind/dom/wohngut.net.zone` (auf `dns01`) enthielt keine DNS-Records,
sondern eine `named.conf`-artige `zone { type master; file ...; };`-Stanza
— augenscheinlich beim Anlegen der Zone in die falsche Datei kopiert
(Datenformat: `.db` = Records, `.zone` = Config-Stanza, siehe
`/etc/bind/dom/porga.de.{zone,db}` als Referenz). `named-checkzone` zeigte
`unbalanced quotes` / `unknown RR type 'type'` etc. — die Zone lud
authoritativ trotzdem (aus dem separat vorhandenen, korrekten `.db`-File),
aber nicht über den erwarteten Konfigurationspfad.

**Diagnose:** `named-checkzone <zone> /etc/bind/dom/<zone>.zone` — nicht nur
`named-checkconf` (ohne `-z` prüft das keine Zoneninhalte).

## Ursache 2 — negatives Caching auf dem internen Resolver

Nach dem Fix auf `dns01` lösten externe Resolver (`9.9.9.9`, `dig` ohne
`@server`) sofort korrekt auf. Innerhalb des Cluster-Pod-Netzwerks schlug
die Auflösung weiter fehl. Talos-Node-DNS (`talosctl get resolvers`) zeigt
`192.168.2.10` als primären, `9.9.9.9` als sekundären Resolver — `.10` ist
ein `dnsmasq` (kein BIND/Unbound), das die vorherige `SERVFAIL`/`NXDOMAIN`
gecacht hatte (Zone lud ja vorher gar nicht).

**Diagnose:** Debug-Pod im Cluster, gezielt gegen beide konfigurierten
Resolver einzeln fragen (`dig @192.168.2.10` vs. `dig @9.9.9.9`) — liefert
nur einer die korrekte Antwort, ist es ein Caching-Problem auf dem anderen,
kein DNS-Server-seitiges.

**Behebung:** `dnsmasq` kann keinen einzelnen Namen gezielt flushen, nur
den gesamten Cache: `kill -HUP <dnsmasq-pid>` (kein Neustart nötig,
DHCP-Leases bleiben erhalten).

## Ursache 3 — HTTP-01 kollidiert mit dem eigenen Ingress (nginx.org NIC)

Mit korrektem DNS blieb die `Challenge` in `pending`, jetzt mit:

```
Event(Ingress cm-acme-http-solver-*): reason: 'Rejected' All hosts are taken by other resources
```

Der von cert-manager automatisch erzeugte HTTP-01-Solver-Ingress
beansprucht denselben Host (`app.wohngut.net`) wie der reguläre
`flurfunk`-Ingress. Der **nginx.org**-Controller (F5/NGINX-Inc, nicht
Community-`ingress-nginx`) lässt zwei eigenständige (nicht als
Master/Minion markierte) Ingress-Objekte für denselben Host nicht
koexistieren — eines wird verworfen.

`horads.de`/`steinba.ch` (dieselbe `http01`-Solver-Konfiguration in
`cluster-issuer.sops.yaml`) sind dafür **kein** funktionierender Beleg,
dass HTTP-01 hier grundsätzlich geht: laut Kommentar in
`apps/base/legacy-proxy/ingress.yaml` nutzt `horads.de` aktuell ein
vorab geladenes Zertifikat und durchläuft den echten HTTP-01-Ablauf gar
nicht. Der Konflikt hätte dort identisch zugeschlagen.

**Zwei mögliche Lösungen, nur eine umgesetzt:**

- **Mergeable Ingresses** (NIC-Feature: `nginx.org/mergeable-ingress-type:
  master`/`minion`, Solver via
  `spec.acme.solvers[].http01.ingress.ingressTemplate.metadata.annotations`
  konfigurierbar) — technisch möglich, aber ungetestetes Neuland in diesem
  Cluster (kein bestehendes Beispiel), deshalb **nicht** gewählt.
- **DNS-01 statt HTTP-01** (umgesetzt): `wohngut.net` vom `http01`- in den
  bestehenden `rfc2136`-Solver verschoben (analog `porga.de`), dafür
  einmalig `update-policy { grant cert-manager. zonesub TXT; };` in der
  Zonen-Stanza auf `dns01` ergänzt (dieselbe Ursache-1-Datei). Kein
  Solver-Ingress mehr nötig, kein Host-Konflikt möglich.

## Konsequenz

- **Neue externe Zone + HTTP-01 im `letsencrypt-prod`/`-staging`-ClusterIssuer
  ist bei diesem Cluster kein sicherer Default-Weg**, sobald die Zone einen
  eigenen, dauerhaften App-Ingress für denselben Host hat. DNS-01 (falls die
  Zone auf `dns01` liegt: `update-policy`-Grant ergänzen, Zone in den
  `rfc2136`-Selector aufnehmen) ist der robustere erste Versuch für jede
  neue App mit eigenem Host.
- Vor jedem HTTP-01-Erstversuch für eine neue Zone: prüfen, ob der Host
  bereits einen eigenen, nicht-Mergeable Ingress hat — falls ja, entweder
  Mergeable-Ingress einrichten (noch ungetestet hier) oder direkt DNS-01
  wählen.
- `named-checkconf` (ohne `-z`) validiert keine Zoneninhalte — für neue
  Zonen immer zusätzlich `named-checkzone` laufen lassen.
