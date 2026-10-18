# Goloom: SQLite nach Postgres ohne Upstream-Werkzeug

## What went wrong

Goloom (v0.3.0) hat zwei getrennte Store-Backends, aber kein Werkzeug, um Daten von
SQLite nach Postgres zu uebernehmen. Ein naiver Import scheiterte im lokalen Test an
drei Stellen, die ein Werkzeug mit automatischer Typableitung (pgloader, vgl.
`roundcube-pgloader-schema-types.md`) still falsch uebernommen haette:

- Das Postgres-Schema hat echte Typen (`uuid`, `boolean`, `timestamptz`, `jsonb`,
  `text[]`), SQLite speichert Text und Integer.
- SQLite schreibt fehlende Zeitstempel als `''` (`log_entries.archived_at`), Postgres
  erwartet `NULL`.
- Eine Spalte heisst anders und hat einen anderen Typ:
  `provider_instances.scopes_json` (JSON-Text) wird zu `scopes` (`text[]`).

Ausserdem lief die App beim Planen schon auf v0.3.0, nicht mehr auf der Version des
ersten Schemavergleichs. Ein Vergleich mit dem falschen Schema hatte fuenf
scheinbar verlorene Spalten gemeldet, mit dem v0.3.0-Schema blieb nur die eine
Umbenennung.

## Why it failed

- Die Schemata beider Backends werden unabhaengig gepflegt; nur die Tabellennamen
  sind identisch.
- Ein CSV-Export unterscheidet `NULL` und `''` nicht.

## The correct approach

So umgesetzt am 18.10.2026 (#270, #272):

- Export je Tabelle mit `sqlite3 -json`. Das unterscheidet `NULL` von `''`.
- Das Postgres-Schema der laufenden Version vorab aus dem Upstream-Tag anwenden
  (`internal/store/postgres/schema.sql`). Danach in **einer** Transaktion
  importieren:
  - Spalten ueber den Namen zuordnen, plus Umbenennungstabelle.
  - Explizit auf den Typ aus `pg_attribute` casten.
  - JSON-Arrays ueber `jsonb_array_elements_text` umwandeln.
  - `''` bei allen Nicht-Text-Typen zu `NULL` machen.
- Einfuegen in Fremdschluessel-Reihenfolge, damit kein Superuser fuer
  `session_replication_role` noetig ist.
- Abbrechen bei jeder Tabelle oder Spalte ohne Ziel und bei abweichender
  Zeilenzahl. Eine Marker-Tabelle verhindert einen zweiten Lauf.
- Belegt vorab lokal gegen das Produktiv-Backup, mit Postgres 17.2 als normalem
  DB-Owner. `pgcrypto` ist eine vertrauenswuerdige Extension und braucht keinen
  Superuser.
  - Zeilenweiser Wertevergleich nach Typnormalisierung: 21.179 Werte, 0 Abweichungen.
  - App offline gestartet: kein Internet, falscher `ENCRYPTION_KEY`, damit der
    Scheduler nichts veroeffentlicht.
- Umstellung per ArgoCD-PreSync-Hooks:
  - Wave -2 skaliert die App per API auf 0. Dieser Job mountet kein PVC.
  - Wave -1 exportiert und importiert.
  - Danach startet der Sync die App mit `database.type: postgres`.
  - Ausfall rund 40 s.
- Der Upstream-Chart liest `DATABASE_URL` nur aus `secret.existingSecret`. Deshalb
  stehen dieselben Zugangsdaten in `goloom-secrets` und im CNPG-`initdb`-Secret.

## Prevention

- Vor jeder Datenmigration das Schema **der laufenden Version** vergleichen, nicht
  das einer gemerkten.
- Hooks, die ein RWO-PVC mounten, nicht im selben Pod die App stoppen lassen: Liegt
  der Hook-Pod auf einem anderen Node, haengt er an Multi-Attach, bevor er stoppen
  kann. Einmal-Hooks nach erfolgreicher Umstellung wieder entfernen.
- Die Skripte stehen in der Git-Historie von #272, unter `apps/base/goloom/migration/`.
