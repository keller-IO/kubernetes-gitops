#!/bin/sh
# Einmal-Migration SQLite -> Postgres, Schritt 1 (Image keinos/sqlite3).
# Exportiert jede Tabelle als JSON (sqlite3 -json unterscheidet NULL und ''),
# dazu die Zeilenzahl je Tabelle. Laeuft im Init-Container, waehrend Kite
# gestoppt ist; die PVC ist read-only gemountet und bleibt als Rueckfallstand
# unveraendert (Kite nutzt journal_mode=delete, es gibt keine -wal-Datei).
set -eu
DB=${SQLITE_DB:-/data/kite.db}
OUT=${EXPORT_DIR:-/migrate}
if [ ! -f "$DB" ]; then
  echo "keine SQLite-DB unter $DB"; : > "$OUT/counts.txt"; exit 0
fi
URI="file:$DB?mode=ro"
: > "$OUT/counts.txt"
for t in $(sqlite3 "$URI" "select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name"); do
  n=$(sqlite3 "$URI" "select count(*) from \"$t\"")
  if [ "$n" -gt 0 ]; then sqlite3 -json "$URI" "select * from \"$t\"" > "$OUT/$t.json"; fi
  echo "$t $n" >> "$OUT/counts.txt"
done
echo "Export: $(wc -l < "$OUT/counts.txt") Tabellen, $(awk '{s+=$2} END {print s}' "$OUT/counts.txt") Zeilen"
cat "$OUT/counts.txt"
sha256sum "$DB"
