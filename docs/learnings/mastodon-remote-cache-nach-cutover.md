# Mastodon: Remote-Cache nach dem Cutover und tootctl-Fallen

Stand 20.10.2026, Cutover von mastodon02 in den Cluster am 19.10.2026.

## Symptom

Nach dem Cutover fehlten auf jit.social die Profilbilder fremder Accounts und
die Bilder älterer Fremd-Posts in den Timelines. Lokale Avatare und neu
eingehende Medien funktionierten.

```
curl -sI https://jit.social/system/cache/accounts/avatars/000/000/040/original/5bf62332596410ce.jpg
# HTTP/1.1 403 Forbidden ... <Code>AccessDenied</Code>
```

Der Ceph-RGW antwortet bei anonymem Zugriff auf ein **fehlendes** Objekt mit
`403 AccessDenied`, nicht mit 404, weil der Bucket nicht öffentlich listbar
ist. Ein erfundener Pfad unter `/system/` liefert ebenfalls 403. Ein 403 ist
hier also kein Rechteproblem, sondern bedeutet, dass das Objekt fehlt.

## Mechanismus

- Der Remote-Cache (`public/system/cache/`, 272 GB) wurde bewusst nicht
  migriert (Runbook, Entscheidung 22.09.2026). Die Datenbank kam aber
  vollständig per Replica-Promotion mit. 278.523 Fremd-Accounts und alle älteren
  Fremd-Anhänge verwiesen damit auf Dateien, die es im Bucket nicht gibt.
- Mastodon lädt einen Avatar nur nach, wenn sich die Remote-URL ändert oder
  der Dateiname leer ist (`Remotable#avatar_remote_url=`). Ein fehlendes
  Objekt bei gesetztem Dateinamen heilt sich nie von selbst. Dasselbe gilt für
  Header und Anhänge.
- `tootctl media remove --prune-profiles` bearbeitet **nur** Avatare und
  Header, Anhänge lässt es aus (`lib/mastodon/cli/media.rb`). Der Retention-
  CronJob hatte nur diesen Aufruf, eine Anhang-Retention lief also gar nicht.
- Die Retention-Jobs laufen mit `readOnlyRootFilesystem` und einem
  `/tmp`-emptyDir. emptyDirs sind `0777` ohne Sticky-Bit. Rubys `Dir.tmpdir`
  lehnt das ab, und jeder Download scheitert mit `ArgumentError: could not find
  a temporary directory`. Zum Löschen ist das egal, Downloads brauchen ein
  `/tmp` mit Sticky-Bit (das aus dem Image, wie bei Sidekiq).

## Korrektur

Einmalige Jobs im Namespace `mastodon`, erzeugt per
`kubectl create job --from=cronjob/mastodon-media-remove` mit ersetztem
Kommando, ohne `readOnlyRootFilesystem` und ohne `/tmp`-Volume:

1. Avatar und Header aller Fremd-Accounts mit Follow-Beziehung zu lokalen
   Nutzern per `rails runner` neu laden (`reset_avatar!`/`reset_header!`, wie
   `tootctl accounts refresh`). Das betraf 3.943 Accounts, 3.633 gelangen.
   Quellen, die 404 oder 410 liefern, nicht mehr existieren oder ungültige
   Bilder ausliefern, werden geleert. Dann zeigt Mastodon das Standardbild
   statt eines kaputten Bildes.
2. `media remove --days 7 --prune-profiles` einmalig mit 14 h Frist laufen
   lassen. Es besuchte 314.403 Accounts in 6 h 44 min und leerte die Verweise.
3. Accounts, die der Altserver in der Woche vor dem Cutover noch aktualisiert
   hatte, überspringt der Prune (`--days 7`). Für sie ein weiterer Lauf: per
   `exists?` (S3-HEAD) prüfen und nur fehlende Bilder neu laden.
4. Fremd-Anhänge der Follows und ihrer Boosts seit 16.10. ebenso per `exists?`
   prüfen und neu laden (`reset_file!`/`reset_thumbnail!`). Ältere Anhänge
   bleiben leer, wie entschieden. Die Retention würde sie nach 7 Tagen ohnehin
   entfernen.
5. CronJob `mastodon-media-attachments-remove` (`media remove --days 7` ohne
   Flags, täglich 01:00, 4 h Frist) ergänzt.

## Durchsatz

Prune und Refresh schaffen etwa 400 bis 500 Datensätze pro Minute,
unabhängig von `--concurrency` (5 und 15 gemessen). Die Datenbank wartet auf
`WALWrite`, also auf die fsync-Latenz des Ceph-Volumes. Mehr Threads stauen
sich nur vor `COMMIT` und bremsen die Web-Abfragen. Der erste Lauf des
Anhänge-Jobs trifft 186.428 Altanhänge und braucht deshalb zwei Nächte.

## Vorbeugung

- `scripts/ci/guardrails.sh` verlangt in `media-retention.yaml` einen
  `media remove`-Aufruf ohne `--prune-profiles`/`--remove-headers`.
- Bei künftigen Mastodon-Migrationen ohne Remote-Cache die Verweise **im
  Wartungsfenster** leeren (`media remove --days 0`, einmal mit und einmal ohne
  `--prune-profiles --include-follows`) und danach die Profile der Follows neu
  laden. Sonst sehen Nutzer ab der ersten Minute kaputte Bilder.
