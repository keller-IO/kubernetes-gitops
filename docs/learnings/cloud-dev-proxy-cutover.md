# Cloud-dev Proxy-Cutover: Bind-Mount-Inodes und Trusted Proxies

## Symptom

Beim Cutover von `cloud-dev.savar.de` auf
`Traefik -> nginx-inc -> nc01-dev` traten zwei Fehler auf:

1. Die Traefik-Datei auf dem Host enthielt bereits den neuen Cluster-Service,
   Public Requests liefen aber weiterhin direkt zu `192.168.2.220`.
2. Nach erfolgreicher Umschaltung scheiterte `notify_push:setup` mit
   `push server is not a trusted proxy`.

## Ursachen

`dynamic_conf.yml` ist nicht als Teil eines Verzeichnisses, sondern als einzelne
Datei nach `/dynamic_conf.yml` in den Traefik-Container bind-gemountet. Der
atomare Austausch per `mv` ersetzte den Host-Inode. Der laufende Container hielt
weiterhin den alten, nicht mehr unter dem Host-Pfad sichtbaren Inode und Traefik
lud deshalb weiterhin die alte Konfiguration.

Beim anschliessenden Schreiben in den bestehenden Container-Inode sah der
File-Watcher kurz den durch `O_TRUNC` geleerten Inhalt und lud eine Konfiguration
ohne Router. Das zeigte sich als Traefik-`404`. Ein weiterer File-Event auf der
vollstaendig geschriebenen Datei lud die korrekte Konfiguration.

Der neue nginx-inc-Hop fuegte ausserdem eine Adresse aus `10.244.0.0/16` in die
`X-Forwarded-For`-Kette ein. Nextcloud vertraute nur `192.168.2.0/24`, localhost
und IPv6-localhost. Es stoppte die Auswertung deshalb an der Pod-Adresse, statt
den vom Push-Test gesetzten Client `1.2.3.4` zu uebernehmen.

## Diagnose

Host- und Container-Inhalt des Single-File-Mounts vergleichen:

```bash
ssh root@192.168.2.15 \
  'sha256sum /opt/containers/traefik/data/dynamic_conf.yml; docker exec traefik sha256sum /dynamic_conf.yml'
```

Der alte Direct-Pfad war auch am Traefik-Sticky-Cookie `nc-dev_affinity`
erkennbar. Der Cluster-Service setzt diesen Cookie nicht.

Die komplette Push-Kette pruefen:

```bash
ssh root@192.168.2.220 \
  'sudo -u www-data php8.4 /var/www/nextcloud/occ notify_push:setup https://cloud-dev.savar.de/push'
```

## Konsequenz

- Eine einzeln bind-gemountete Datei nicht unbemerkt per atomarem Rename
  ersetzen. Nach einem Inode-Wechsel den Container kontrolliert neu starten oder
  den bestehenden Mount aktualisieren und Hash sowie Runtime-Verhalten pruefen.
- Langfristig das Traefik-Konfigurationsverzeichnis statt einer einzelnen Datei
  mounten; dann folgt der Container atomaren Dateiaustauschen im Verzeichnis.
- Bei einem neuen Reverse-Proxy-Hop die gesamte `X-Forwarded-For`-Kette mit dem
  Anwendungstest pruefen. Fuer diesen Cluster muss Nextcloud dem stabilen
  Pod-CIDR `10.244.0.0/16` vertrauen, nicht einzelnen vergaenglichen Pod-IPs.
- `notify_push:setup` mit der bereits laufenden externen URL aufrufen. Ohne
  `https://cloud-dev.savar.de/push` versucht der Assistent einen neuen Daemon auf
  Port 7867 einzurichten und meldet nur, dass der Port belegt ist.
