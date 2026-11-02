# CNPG: Backup auf dem Standby endet in nicht archiviertem WAL

## Symptom

Befund 02.11.2026 (Forgejo wurde am selben Tag aus Git entfernt; die Messwerte bleiben als Beleg stehen): Bei `forgejo-pg`, `expense-pg` und `ciso-assistant-pg` meldeten
die Backups `completed`, `LastBackupSucceeded` und `ContinuousArchiving` waren `True`.
Trotzdem lag das Ende-WAL des Backups nach dem zuletzt archivierten Segment:

| Cluster | `status.endWal` des jüngsten Backups | zuletzt archiviert |
| --- | --- | --- |
| forgejo-pg | `000000020000000100000026` | `...25` am 19.10. |
| expense-pg | `00000003000000000000008D` | `...8C` am 21.10. |
| ciso-assistant-pg | `000000020000000000000075` | `...74` am 23.10. |

## Mechanismus

Der Cluster-Default ist `backup.target: prefer-standby`. Auf einem Standby erzwingt
`pg_backup_stop` keinen WAL-Switch, und `archive_timeout` greift nur, wenn seit dem
letzten Switch relevantes WAL entstand. Auf schreibruhigen Clustern endet das Backup
deshalb in einem Segment, das noch nicht archiviert ist; der Status bleibt trotzdem
`completed`.

## Folge

Diese Backups lassen sich allein aus dem Objektspeicher nicht wiederherstellen,
solange das Segment nur im `pg_wal` der Primary liegt. Aktuelle Daten sind nicht
verloren (ohne relevantes WAL gab es keine neuen Commits), und ältere Backups vor
dem jeweiligen Datum sind noch wiederherstellbar. Bei 30 d Retention laufen sie
aber ab etwa Mitte November aus dem Fenster. Forgejo stand zudem auf 0 Replicas und
heilte sich ohne Schreiblast nicht selbst (inzwischen entfernt, siehe oben).

## Korrektur

`target: primary` auf den ScheduledBackups schreibruhiger Cluster (PR #449); dort
sollte `pg_backup_stop` den Switch erzwingen. Schreibaktive Cluster bleiben auf
`prefer-standby`, weil dort laufend neues WAL entsteht und Segmente regelmäßig
archiviert werden. Beides ist Erwartung, noch kein Laufzeitnachweis: nach dem
jeweils nächsten Backup die Prüfung unten ausführen und das Ergebnis hier eintragen.

## Prüfung

Je Cluster `status.endWal` des jüngsten Backups gegen `last_archived_wal` aus
`pg_stat_archiver` vergleichen; `endWal` darf nicht größer sein.

```
$ kubectl -n <ns> get backup -o jsonpath='{range .items[*]}{.metadata.creationTimestamp} {.status.endWal}{"\n"}{end}' | sort | tail -1
$ kubectl cnpg psql -n <ns> <cluster> -- -c "select last_archived_wal, last_archived_time from pg_stat_archiver"
```
