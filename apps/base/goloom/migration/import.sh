#!/bin/bash
# Einmal-Migration SQLite -> Postgres, Schritt 2 (Image cloudnative-pg/postgresql).
# Legt das Postgres-Schema von Goloom an und uebernimmt den Export aus Schritt 1
# in EINER Transaktion; die Zeilenzahl jeder Tabelle wird gegen SQLite geprueft.
# Laeuft nur einmal: danach existiert public._goloom_sqlite_import.
set -euo pipefail
: "${DATABASE_URL:?}"
IN=${EXPORT_DIR:-/migrate}
SQLDIR=${SQL_DIR:-/migration}

for i in $(seq 1 60); do pg_isready -q -d "$DATABASE_URL" && break; echo "warte auf Postgres ($i)"; sleep 5; done
pg_isready -d "$DATABASE_URL"

if [ "$(psql "$DATABASE_URL" -Atc "select to_regclass('public._goloom_sqlite_import') is not null")" = t ]; then
  echo "Import bereits erfolgt:"; psql "$DATABASE_URL" -Atc "select * from public._goloom_sqlite_import"; exit 0
fi
if [ ! -s "$IN/counts.txt" ]; then echo "kein SQLite-Export vorhanden, Abbruch"; exit 1; fi

LOAD=$(mktemp)
{
  echo "create temp table _cnt (tname text primary key, n bigint not null) on commit drop;"
  echo "create temp table _imp (tname text primary key, data jsonb not null) on commit drop;"
  while read -r t n; do
    echo "insert into _cnt values ('$t', $n);"
    if [ "$n" -gt 0 ]; then
      echo "\\set d \`cat $IN/$t.json\`"
      echo "insert into _imp values ('$t', :'d'::jsonb);"
    fi
  done < "$IN/counts.txt"
} > "$LOAD"

psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -1 \
  -f "$SQLDIR/postgres-schema.sql" -f "$LOAD" -f "$SQLDIR/import.sql"
echo "Import abgeschlossen."
