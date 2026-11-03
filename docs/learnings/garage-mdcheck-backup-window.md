# Garage: zufälliger mdadm-Prüflauf überlagert das Backup-Fenster

## Symptom

Am 03.11.2026 schlugen 5 von 9 CNPG-Basisbackups zwischen 02:00 und 02:50 UTC fehl
(`mailman-pg`, `expense-pg`, `monitoring-pg`, `ciso-assistant-pg`, `goloom-pg`). Im
Pod-Log stand `barman-cloud-backup` mit „Read timeout on endpoint URL“ und „Connection
was closed before we received a valid response“; im Garage-Log erschienen 139 HTTP-500
„error reading a body from connection“. Es ging kein Alert raus.

## Mechanismus

Garage (LXC 8021, 1 Kern, 1 GiB) und PBS schreiben auf `/data` des Hosts `u22`, ein
mdadm-RAID1 aus zwei HDDs. Debians `mdcheck_continue.timer` (`OnCalendar=daily`,
`RandomizedDelaySec=12h`) startet den Prüflauf zu einer zufälligen Uhrzeit und läuft bis
zu 6 h. Am 03.11. fiel der Start (01:47 UTC) vor das Backup-Fenster; das Array las mit
150–160 MB/s bei 66–75 % Auslastung, Uploads liefen in Timeouts. An Tagen, an denen der
Lauf später beginnt (02.11.: 04:17 UTC), laufen die Backups durch. Die Korrelation ist
stark, aber nicht experimentell nachgestellt; die 1-GiB-Grenze des Garage-Containers
(`sock_throttled`) kann Mitursache sein.

## Korrektur

Der `mdcheck`-Zeitplan wird so festgelegt, dass er das Backup-Fenster nicht trifft, und
der Alarm `kellerio-cnpg-backup-failed` meldet fehlgeschlagene Basisbackups: beides
im zentralen Ansible-Repo, nicht hier. Ob das wirkt, zeigt erst der Backup-Lauf am
04.11. ca. 02:00–03:00 UTC (noch nicht geprüft).

## Prüfung

`completed` oder `failed` am Backup-Objekt reicht nicht; `lastSuccessfulBackup` im
Clusterstatus widersprach am 03.11. dem Objekt. Zusätzlich:

```bash
# Backup-Objekte und Clusterstatus
kubectl -n <ns> get backups.postgresql.cnpg.io
kubectl -n <ns> get clusters.postgresql.cnpg.io <cluster> \
  -o jsonpath='{.status.lastSuccessfulBackup}{"\n"}{.status.lastFailedBackup}{"\n"}'
# Das Backup läuft in der Instanz, siehe status.instanceID.podName am Backup-Objekt
kubectl -n <ns> logs <instanz-pod> -c postgres --since=12h \
  | grep -E 'Read timeout|Connection was closed'
# Auf dem Garage-CT: erwartet ist HTTP 500 "error reading a body from connection"
docker logs garage --since <start> --until <ende> 2>&1 | grep 'error 500' | cut -c1-16 | uniq -c
# Auf u22
journalctl -u 'mdcheck*' --since '-2 days'
sar -d -f /var/log/sysstat/sa<DD>
```

## Prävention

Kein CI-Guardrail: Die Ursache liegt auf dem Host `u22` außerhalb dieses Repos, in den
Manifesten gibt es kein prüfbares Muster. Vorbeugung sind der Zeitplan und der Alarm
im zentralen Ansible-Repo.
