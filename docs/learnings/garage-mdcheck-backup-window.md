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

```
$ kubectl -n <ns> get backup
$ kubectl -n <ns> logs <backup-pod> | grep -E 'Read timeout|Connection was closed'
$ journalctl -u 'mdcheck*' --since '-2 days'          # auf u22
$ sar -d -f /var/log/sysstat/sa<DD>                   # auf u22, Auslastung von md0
```

Garage-Log auf HTTP 500 „error reading a body from connection“ im Backup-Fenster prüfen.

## Prävention

Kein CI-Guardrail: Die Ursache liegt auf dem Host `u22` außerhalb dieses Repos, in den
Manifesten gibt es kein prüfbares Muster. Vorbeugung sind der Zeitplan und der Alarm
im zentralen Ansible-Repo.
