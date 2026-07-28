#!/usr/bin/env python3
"""SQLite -> PostgreSQL Datenkopie fuer die Mailman-Web-DB (HyperKitty/Postorius).

Einmal-Werkzeug fuer die Migration von 192.168.2.15; absichtlich nicht in
kustomization.yaml. Ablauf und Messwerte stehen in
docs/runbooks/mailman-migration.md.

Aufruf (im Helper-Pod, der das maxking/mailman-web-Image nutzt und damit
psycopg2 und das sqlite3-Modul mitbringt):

    SQLITE_PATH=/data/mailmanweb.db \\
    PG_DSN='host=mailman-pg-rw port=5432 dbname=mailmanweb user=mailman password=...' \\
    python3 migration-sqlite-to-postgres.py

Im Probelauf am 28.07.2026 verifiziert: 99.983 Zeilen in 403 s, danach
0 Abweichungen bei den Zeilenzahlen aller 34 Tabellen.

Bewusst KEIN pgloader: das Zielschema wird von Django angelegt und ist korrekt;
pgloader wuerde die Typen aus SQLites dynamischer Typisierung neu raten (genau
der Fehler aus der Roundcube-Migration, siehe docs/learnings/). Hier wird
stattdessen Zeile fuer Zeile kopiert und pro Spalte anhand des PG-Typs gecastet.

Alles laeuft in EINER Transaktion mit SET CONSTRAINTS ALL DEFERRED. Djangos
Fremdschluessel sind DEFERRABLE INITIALLY DEFERRED (geprueft: 39/39), damit ist
die Ladereihenfolge egal und es braucht keine Superuser-Rechte zum Abschalten
von Triggern.
"""
import datetime
import os
import sqlite3
import sys
import time

import psycopg2
import psycopg2.extras

SQLITE_PATH = os.environ["SQLITE_PATH"]
PG_DSN = os.environ["PG_DSN"]
# Nach BYTES begrenzen, nicht nach Zeilen: hyperkitty_attachment.content ist im
# Schnitt 94 KB, das groesste Attachment aber 15 MB. Bei fester Zeilenzahl haengt
# die Statementgroesse davon ab, welche Zeilen zufaellig zusammenfallen -- genau
# daran ist der erste Probelauf gescheitert (PG-Pod OOMKilled).
MAX_BATCH_BYTES = int(os.environ.get("MAX_BATCH_BYTES", str(8 * 1024 * 1024)))
MAX_BATCH_ROWS = int(os.environ.get("MAX_BATCH_ROWS", "500"))

# django_q ist die Async-Taskqueue: django_q_ormq (offene Jobs) und
# django_q_schedule (Zeitplaene) sind in der Quelle leer, django_q_task haelt
# nur abgeschlossene Task-Ergebnisse. Nichts davon gehoert in die neue
# Installation -- alte Jobs wuerden dort sogar erneut anlaufen.
EXCLUDE = set(
    t.strip()
    for t in os.environ.get(
        "EXCLUDE", "django_q_ormq,django_q_schedule,django_q_task"
    ).split(",")
    if t.strip()
)


def pg_columns(cur, table):
    """Spaltennamen + PG-Typ in Definitionsreihenfolge."""
    cur.execute(
        """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = %s
        ORDER BY ordinal_position
        """,
        (table,),
    )
    return cur.fetchall()


NUL_STRIPPED = {}


def convert(value, pgtype, table=None, column=None):
    """SQLite-Wert auf den PG-Spaltentyp abbilden."""
    if value is None:
        return None

    if pgtype in ("character varying", "text") and isinstance(value, str) and "\x00" in value:
        # PostgreSQL kann 0x00 in text/varchar grundsaetzlich nicht speichern,
        # SQLite schon. Entfernen ist die einzige Moeglichkeit; wir zaehlen mit,
        # damit die Aenderung sichtbar bleibt und nicht still passiert.
        key = "%s.%s" % (table, column)
        NUL_STRIPPED[key] = NUL_STRIPPED.get(key, 0) + 1
        value = value.replace("\x00", "")

    if pgtype == "boolean":
        # SQLite speichert Django-BooleanFields als 0/1.
        if isinstance(value, (int, float)):
            return bool(value)
        if isinstance(value, str):
            return value.strip().lower() in ("1", "t", "true", "yes")
        return bool(value)

    if pgtype == "bytea":
        # BinaryField: sqlite3 liefert bytes; str kann bei Altdaten vorkommen.
        if isinstance(value, memoryview):
            return psycopg2.Binary(value.tobytes())
        if isinstance(value, bytes):
            return psycopg2.Binary(value)
        if isinstance(value, str):
            return psycopg2.Binary(value.encode("utf-8", "surrogateescape"))
        return value

    if pgtype in ("timestamp with time zone", "timestamp without time zone"):
        # Django/SQLite legt Zeitstempel als 'YYYY-MM-DD HH:MM:SS[.ffffff][+00:00]' ab.
        if isinstance(value, str):
            text = value.strip()
            if not text:
                return None
            text = text.replace("T", " ")
            if text.endswith("Z"):
                text = text[:-1] + "+00:00"
            for fmt in (
                "%Y-%m-%d %H:%M:%S.%f%z",
                "%Y-%m-%d %H:%M:%S%z",
                "%Y-%m-%d %H:%M:%S.%f",
                "%Y-%m-%d %H:%M:%S",
                "%Y-%m-%d",
            ):
                try:
                    parsed = datetime.datetime.strptime(text, fmt)
                except ValueError:
                    continue
                if pgtype.endswith("time zone") and parsed.tzinfo is None:
                    parsed = parsed.replace(tzinfo=datetime.timezone.utc)
                return parsed
            raise ValueError("Unlesbarer Zeitstempel: %r" % value)
        return value

    if pgtype == "date" and isinstance(value, str):
        return datetime.datetime.strptime(value.strip()[:10], "%Y-%m-%d").date()

    if pgtype == "time without time zone" and isinstance(value, str):
        return value.strip()

    if pgtype in ("character varying", "text") and isinstance(value, bytes):
        # Vereinzelt liegen Textspalten in SQLite als BLOB vor.
        return value.decode("utf-8", "replace")

    return value


def main():
    sq = sqlite3.connect(SQLITE_PATH)
    sq.text_factory = bytes  # selbst dekodieren, SQLite-Altdaten sind nicht sauber UTF-8
    sq.row_factory = None

    pg = psycopg2.connect(PG_DSN)
    pg.autocommit = False
    pcur = pg.cursor()
    # session_replication_role waere superuser-pflichtig und ist unnoetig:
    # die Fremdschluessel sind DEFERRABLE, das reicht.
    pcur.execute("SET CONSTRAINTS ALL DEFERRED")

    # Zieltabellen (Django-Schema) mit ihren Spalten.
    pcur.execute(
        """
        SELECT table_name FROM information_schema.tables
        WHERE table_schema='public' AND table_type='BASE TABLE'
        ORDER BY table_name
        """
    )
    tables = [r[0] for r in pcur.fetchall()]

    scur = sq.cursor()
    scur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    src_tables = {r[0].decode() if isinstance(r[0], bytes) else r[0] for r in scur.fetchall()}

    # ALLE Zieltabellen in EINEM Statement leeren. Einzelne TRUNCATE ... CASCADE
    # waeren ein Datenverlust-Fehler: CASCADE raeumt abhaengige Tabellen mit ab
    # und wuerde bereits geladene Tabellen wieder leeren.
    pcur.execute(
        "TRUNCATE TABLE %s CASCADE"
        % ", ".join('"%s"' % t for t in tables)
    )

    total_rows = 0
    started = time.time()
    report = []

    for table in tables:
        if table in EXCLUDE:
            print("  %-40s %8s uebersprungen" % (table, "-"), flush=True)
            continue
        if table not in src_tables:
            report.append((table, 0, "nicht in SQLite"))
            continue

        cols = pg_columns(pcur, table)
        colnames = [c[0] for c in cols]
        coltypes = [c[1] for c in cols]

        # Nur Spalten nehmen, die es auf beiden Seiten gibt.
        scur.execute('PRAGMA table_info("%s")' % table)
        src_cols = {
            (r[1].decode() if isinstance(r[1], bytes) else r[1]) for r in scur.fetchall()
        }
        use = [(n, t) for n, t in zip(colnames, coltypes) if n in src_cols]
        missing = [n for n in colnames if n not in src_cols]
        if not use:
            report.append((table, 0, "keine gemeinsamen Spalten"))
            continue

        quoted = ", ".join('"%s"' % n for n, _ in use)
        scur.execute("SELECT %s FROM %s" % (quoted, '"%s"' % table))

        insert = 'INSERT INTO "%s" (%s) VALUES %%s' % (table, quoted)
        n = 0
        batch = []
        batch_bytes = 0

        def flush():
            if batch:
                psycopg2.extras.execute_values(
                    pcur, insert, batch, page_size=len(batch)
                )
                del batch[:]

        while True:
            row = scur.fetchone()
            if row is None:
                break
            out = []
            size = 0
            for value, (colname, pgtype) in zip(row, use):
                if isinstance(value, bytes):
                    size += len(value)
                    if pgtype != "bytea":
                        value = value.decode("utf-8", "replace")
                elif isinstance(value, str):
                    size += len(value)
                else:
                    size += 8
                out.append(convert(value, pgtype, table, colname))
            batch.append(tuple(out))
            batch_bytes += size
            n += 1
            if batch_bytes >= MAX_BATCH_BYTES or len(batch) >= MAX_BATCH_ROWS:
                flush()
                batch_bytes = 0
        flush()

        note = "ohne %s" % ",".join(missing) if missing else ""
        report.append((table, n, note))
        total_rows += n
        print("  %-40s %8d %s" % (table, n, note), flush=True)

    # Sequenzen auf den Hoechstwert setzen, sonst kollidiert der erste INSERT der App.
    pcur.execute(
        """
        SELECT c.relname, a.attname, s.relname
        FROM pg_class s
        JOIN pg_depend d ON d.objid = s.oid AND d.deptype = 'a'
        JOIN pg_class c ON c.oid = d.refobjid
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.refobjsubid
        WHERE s.relkind = 'S'
        """
    )
    seqs = pcur.fetchall()
    for tbl, col, seq in seqs:
        pcur.execute(
            'SELECT setval(%%s, COALESCE((SELECT MAX("%s") FROM "%s"), 1), '
            "(SELECT MAX(\"%s\") IS NOT NULL FROM \"%s\"))" % (col, tbl, col, tbl),
            (seq,),
        )

    print("\nCommit (hier greifen die aufgeschobenen Fremdschluessel) ...", flush=True)
    t0 = time.time()
    pg.commit()
    commit_s = time.time() - t0

    elapsed = time.time() - started
    if NUL_STRIPPED:
        print("\nNUL-Bytes entfernt (nicht in PostgreSQL text speicherbar):")
        for key in sorted(NUL_STRIPPED):
            print("  %-40s %d Werte" % (key, NUL_STRIPPED[key]))
    print("\nZeilen gesamt: %d" % total_rows)
    print("Sequenzen gesetzt: %d" % len(seqs))
    print("Dauer Laden: %.1f s, davon Commit %.1f s" % (elapsed, commit_s))


if __name__ == "__main__":
    sys.exit(main())
