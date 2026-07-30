# cloud-dev.savar.de ueber den Kubernetes-Ingress routen

Nextcloud selbst bleibt auf `nc01-dev` (`192.168.2.220`). Nur der
Reverse-Proxy-Pfad wechselt von der direkten Traefik-Verbindung auf nginx-inc:

```text
Internet -> Traefik .15 (TLS) -> Cluster-LB .246 (HTTP)
         -> nginx-inc -> nc01-dev:443 (HTTPS)
                      -> nc01-dev:7867 (notify_push, /push ohne Prefix)
```

`nc02-dev` (`192.168.2.221`) ist aktuell nicht erreichbar und bleibt aus dem
Upstream. nginx-inc kann ExternalName-Services in dieser Installation nicht
aufloesen. Daher verwenden die Kubernetes-Services feste EndpointSlices fuer
`192.168.2.220`; ArgoCD schliesst EndpointSlices clusterweit von Sync und Prune
aus.

## Voraussetzungen

1. Der GitOps-Branch mit `Ingress/legacy-proxy/cloud-dev` ist nach `main`
   gemergt.
2. ArgoCD meldet `app-legacy-proxy` als `Synced` und `Healthy`.
3. Die von ArgoCD ausgeschlossenen EndpointSlices sind einmalig manuell
   angewendet:

   ```bash
   kubectl apply -f apps/base/legacy-proxy/external-backends.yaml
   ```

4. Der Ingress hat ein `AddedOrUpdated`-Event, kein `Rejected`.
5. Der direkte Clusterpfad liefert Nextcloud 34.0.1:

   ```bash
   curl --resolve cloud-dev.savar.de:80:192.168.2.246 \
     -H 'X-Forwarded-Proto: https' \
     http://cloud-dev.savar.de/status.php
   ```

   Erwartet: HTTP 200, `installed=true`, `maintenance=false`.

6. Nextcloud vertraut neben dem LAN auch dem Cluster-Pod-CIDR. Der aktuelle
   vierte Eintrag ist `10.244.0.0/16`:

   ```bash
   ssh root@192.168.2.220 \
     'sudo -u www-data php8.4 /var/www/nextcloud/occ config:system:get trusted_proxies'
   ```

   Fehlt der CIDR, nach Sicherung von `config.php` ergaenzen:

   ```bash
   ssh root@192.168.2.220 \
     'sudo -u www-data php8.4 /var/www/nextcloud/occ config:system:set trusted_proxies 3 --value=10.244.0.0/16'
   ```

## Traefik umstellen

Datei auf `192.168.2.15`:
`/opt/containers/traefik/data/dynamic_conf.yml`.

1. Datei mit Zeitstempel sichern.
2. Beim Router `jitcloud-dev_router` den Service von
   `jitcloud-dev_service` auf `jitcloud-dev_k8s_service` umstellen.
3. Den separaten `jitcloud-dev_push_router` deaktivieren. `/push/` muss
   unveraendert am Cluster ankommen; nginx-inc uebernimmt WebSocket und
   Strip-Prefix.
4. Folgenden Service ergaenzen:

   ```yaml
   jitcloud-dev_k8s_service:
     loadBalancer:
       servers:
         - url: http://192.168.2.246:80
   ```

Vor dem Speichern auf korrekte YAML-Einrueckung achten. Die Datei ist als
einzelne Datei nach `/dynamic_conf.yml` in den Container bind-gemountet. Ein
atomarer Austausch per `mv` erzeugt auf dem Host einen neuen Inode, waehrend der
laufende Container die alte Datei behaelt. Nach einem solchen Austausch Traefik
kontrolliert neu starten oder den bestehenden Mount-Inode aktualisieren und einen
neuen File-Event ausloesen. Anschliessend muessen beide Hashes uebereinstimmen:

```bash
ssh root@192.168.2.15 \
  'sha256sum /opt/containers/traefik/data/dynamic_conf.yml; docker exec traefik sha256sum /dynamic_conf.yml'
```

Danach die Traefik-Logs auf Parserfehler pruefen. Ein `404` von Traefik direkt
nach dem Schreiben weist darauf hin, dass der File-Watcher einen temporaer
leeren Zwischenstand geladen hat; den Event dann auf der vollstaendigen Datei
erneut ausloesen.

## Verifikation

```bash
curl -fsS https://cloud-dev.savar.de/status.php
curl -fsSI https://cloud-dev.savar.de/login
ssh root@192.168.2.220 \
  'sudo -u www-data php8.4 /var/www/nextcloud/occ notify_push:setup https://cloud-dev.savar.de/push'
```

Zusatztests:

1. OIDC-Login ueber Keycloak.
2. WebDAV-Sync sowie Up- und Download einer Testdatei.
3. Browser- und Desktop-Push ohne Fehler.
4. Gatus-Endpunkt `nextcloud-dev` bleibt gruen.

## Rollback

1. `dynamic_conf.yml` aus der Sicherung wiederherstellen.
2. Alternativ `jitcloud-dev_router` zurueck auf `jitcloud-dev_service` setzen
   und `jitcloud-dev_push_router` wieder aktivieren.
3. Falls die Datei atomar ersetzt wurde, Traefik neu starten oder den laufenden
   Mount-Inode ebenfalls aktualisieren.
4. `status.php`, Login und `notify_push:setup` erneut pruefen.

Der Rollback veraendert weder Nextcloud-Daten noch Datenbank oder Redis; es wird
nur der Proxy-Pfad zurueckgeschaltet.
