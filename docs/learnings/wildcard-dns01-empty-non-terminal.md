# *.jit.services: DNS-01 macht Wildcard-Namen bis zu einer Stunde unauflösbar

## Symptom

Direkt nach dem ersten Sync von `ciso-assistant` (22.09.2026) war
`grc.jit.services` im LAN nicht auflösbar. Pi-hole (`192.168.2.143`) lieferte
`NOERROR` ohne A-Record (`NODATA`), obwohl `matomo.jit.services` & Co. normal auf
`192.168.2.246` auflösten. Eine gleichzeitige Abfrage direkt bei `1.1.1.1` oder
`pve` (`192.168.2.10`) lieferte dagegen die richtige Adresse. Das Pi-hole-Log zeigt
die Weiterleitung an 1.1.1.1 und `reply grc.jit.services is NODATA-IPv4`.

## Ursache

`*.jit.services` existiert nur als Wildcard bei ClouDNS. Für DNS-01 legt
cert-manager `_acme-challenge.grc.jit.services` (TXT) an. Damit wird
`grc.jit.services` zu einem **leeren Zwischenknoten** (empty non-terminal). Für
einen existierenden Namen greift die Wildcard nicht mehr (RFC 4592), also lautet
die Antwort `NODATA` statt `.246`.

Nach der Challenge löscht cert-manager den TXT-Record, und autoritativ stimmt
wieder alles. Wer aber währenddessen gefragt hat, speichert das `NODATA` für die
Negativ-TTL der Zone: SOA-Minimum **3600 s**. Welcher Resolver betroffen ist,
hängt davon ab, welcher Upstream-Knoten (hier 1.1.1.1) die Frage im
Challenge-Fenster gesehen hat.

## Folgen

- Das betrifft **jede Ausstellung und jede Erneuerung** (etwa alle 60 Tage) für
  **jede** App, die nur über die Wildcard aufgelöst wird: kimai, matomo,
  phpmyadmin, grc und weitere. Der Ausfall dauert bis zu einer Stunde,
  unabhängig davon, ob der Cluster gesund ist.
- Monitoring, das per Name prüft (gatus), sieht in dem Fenster einen DNS-Fehler.

## Abhilfe

- Kurzfristig: abwarten (≤ 1 h) oder den Cache des betroffenen Resolvers leeren.
  Pi-hole: `ssh root@192.168.2.6` → `pct exec 2008 -- pihole reloaddns`. Der
  Upstream 1.1.1.1 behält seinen Eintrag trotzdem bis zum TTL-Ablauf.
- Dauerhaft: für jeden genutzten Namen einen **expliziten A-Record** bei ClouDNS
  anlegen (`grc.jit.services A 192.168.2.246`). Ein explizit existierender Name
  bleibt auflösbar, auch wenn darunter `_acme-challenge` angelegt wird. Die
  Wildcard bleibt als Fallback bestehen.
- Diagnose: autoritativ fragen (`dig grc.jit.services @pns31.cloudns.net`),
  während der Challenge nach `_acme-challenge.<name>` TXT sehen, und im
  Pi-hole-Log nach `NODATA` suchen.
