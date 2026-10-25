# Mastodon: Migration ohne lock_timeout staut die Datenbank

Stand 23.10.2026, Upgrade 4.5.19 → 4.6.9 (#338).

## Symptom

Etwa fünf Minuten nach dem Merge (08:56–09:01Z) waren beide Web-Pods `0/1`
Ready, jit.social antwortete nicht. Der PreSync-Job `mastodon-db-migrate-pre`
lief, kam aber nicht weiter:

```
== 20251217091936 AddFeatureApprovalPolicyToAccounts: migrating
[strong_migrations] DANGER: No lock timeout set
-- add_column(:accounts, :feature_approval_policy, :integer, {null: false, default: 0})
```

`pg_blocking_pids()` in `pg_stat_activity` zeigte die Kette:

| PID | Zustand | Abfrage |
|---|---|---|
| 87228 | aktiv seit 14 min, `wait_event_type=IO` | `REFRESH MATERIALIZED VIEW CONCURRENTLY "account_summaries"` |
| 180367 | wartet auf Lock, blockiert von 87228 | `ALTER TABLE "accounts" ADD "feature_approval_policy" …` |
| 29 weitere | warten auf Lock, blockiert von 180367 | `SELECT … FROM "accounts" …` von Web und Sidekiq |

## Mechanismus

- `ALTER TABLE … ADD COLUMN … DEFAULT` ist seit PostgreSQL 11 eine reine
  Katalogänderung und dauert Millisekunden. Es braucht aber einen
  `ACCESS EXCLUSIVE`-Lock auf der Tabelle.
- Der Lock-Wunsch steht in der Warteschlange. Jede spätere Abfrage auf
  `accounts`, auch ein einfaches `SELECT`, wartet **hinter** dem ALTER, nicht
  neben dem Refresh. Eine wartende Migration legt so die ganze Tabelle still.
- Mastodon setzt keinen `lock_timeout` (`config/database.yml`, das
  strong_migrations-Initializer setzt nur `start_after` und `target_version`).
  strong_migrations warnt nur („DANGER: No lock timeout set“).
- Der Blocker war `Scheduler::FollowRecommendationsScheduler`. Er läuft täglich
  zu einer zufälligen Zeit zwischen 06:00 und 09:59 UTC (`config/sidekiq.yml`)
  und frischt `account_summaries` und `follow_recommendations` auf. Auf den
  langsamen Consumer-SSD-OSDs (`osd.0` 46 ms, `osd.1` 22 ms Commit-Latenz)
  dauerte der Refresh über 14 Minuten. Der Merge um 08:49Z fiel in dieses
  Fenster.

## Korrektur

Den Refresh abbrechen, nicht die Migration:

```bash
kubectl -n mastodon exec mastodon-pg-1 -c postgres -- \
  psql -XAt -c "select pg_cancel_backend(87228)"
```

`CONCURRENTLY` behält den alten Inhalt der View, der Abbruch ist folgenlos.
Der Job hat `retry: 0` und läuft am nächsten Tag wieder. Danach lief das ALTER
sofort durch, die Warteschlange löste sich auf, und der PreSync-Job war um
09:01:52Z fertig. Rollout und PostSync-Job folgten bis 09:03:38Z.

Ein Abbruch der Migration (`pg_cancel_backend` auf das ALTER) hätte den
Ausfall ebenso beendet. Der Sync wäre aber gescheitert und hätte beim nächsten
Versuch auf denselben Lock treffen können.

## Prävention

- Beide Hooks in `apps/base/mastodon/db-migrate.yaml` setzen
  `PGOPTIONS="-c lock_timeout=10s"`. Bei `LockNotAvailable` wiederholt der Job
  `db:migrate` bis zu zehnmal im Abstand von 30 s, andere Fehler brechen sofort
  ab. Rails rollt die gescheiterte Migration zurück, bereits gelaufene bleiben
  in `schema_migrations`. Geprüft gegen das v4.6.9-Image: der `pg`-Gem
  übernimmt `PGOPTIONS`, der Fehler heißt `ActiveRecord::LockWaitTimeout` /
  `PG::LockNotAvailable`.
- Schlimmstenfalls wartet die Tabelle so 10 s statt unbegrenzt. Bleibt der
  Blocker länger als etwa sieben Minuten, scheitert der PreSync-Job und die
  alten Pods laufen weiter.
- Grenze: Migrationen mit `algorithm: :concurrently` (ohne Transaktion) können
  bei einem Lock-Timeout einen `INVALID`-Index hinterlassen. Der nächste
  Versuch scheitert dann mit „already exists“. Das ist kein Ausfall, aber vor
  dem erneuten Sync den Index per `DROP INDEX CONCURRENTLY` entfernen.
- `scripts/ci/check-migration-lock-timeout.sh` (aufgerufen von
  `guardrails.sh`) verlangt für jedes `db:migrate` außerhalb von `charts/`
  ein `lock_timeout=` in derselben Datei – auch in Array-Form wie
  `["bundle", "exec", "rails", "db:migrate"]`. Fixtures dazu in
  `scripts/ci/test-check-migration-lock-timeout.sh`.
- Runbook `docs/runbooks/mastodon-migration.md`, „Versions-Upgrades“: vorher
  lange Transaktionen prüfen und während der Hooks `pg_blocking_pids()`
  beobachten.

## Nachtrag 25.10.2026: ab 4.7 kein `REFRESH` mehr

- Die „14 min“ oben waren das Alter des Refreshs beim Abbruch, nicht seine
  Laufzeit. Vollständig dauerte er laut Scheduler-Log 1.613 s (24.10.) und
  1.024 s (25.10.).
- Mit 4.7.3 (#386) wandelt `ConvertMaterializedViewsToTables` beide Views in
  Tabellen um. `AccountSummary.refresh` löscht und schreibt seitdem in Batches
  (`INSERT … ON CONFLICT`). Jeder Batch hält `ROW EXCLUSIVE` auf der Tabelle
  und Lese-Locks auf `accounts` nur für seine Dauer. Der Stau von oben über
  17 bis 27 min kann so nicht mehr entstehen. `FollowRecommendation.refresh`
  schreibt dagegen in einer einzigen Anweisung und liest dabei `follows`,
  `statuses`, `status_stats` und `users`. Das Sperrfenster 06:00–10:00 UTC
  ist aus dem Runbook entfernt.
- `lock_timeout` und Wiederholung in den Hooks bleiben. Sie schützen auch
  gegen jeden anderen Blocker.
