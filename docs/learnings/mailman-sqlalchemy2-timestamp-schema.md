# Mailman: PostgreSQL-Zeitspalten vor SQLAlchemy 2 angleichen

Beim Upgrade von `maxking/mailman-core` 0.4 auf 0.5.2 wechselte SQLAlchemy von
1.3 auf 2.0. Die aus Mailman 3.3.4 migrierte PostgreSQL-Datenbank hatte zwölf
noch genutzte Zeitspalten als `timestamp with time zone`, obwohl die Mailman-
Modelle `DateTime` ohne Zeitzone deklarieren. Eine frisch von Mailman 3.3.10
angelegte Datenbank verwendet entsprechend `timestamp without time zone`.

SQLAlchemy 1.3 tolerierte diese Drift. Mit SQLAlchemy 2.0 lieferte PostgreSQL
timezone-aware Werte, Mailman verglich sie jedoch mit naiven UTC-Werten. Der
Task-Runner stürzte deshalb beim Bereinigen von `pended.expiration_date`
wiederholt mit `TypeError: can't compare offset-naive and offset-aware
datetimes` ab, obwohl der Pod selbst weiter als Running erschien.

Vor dem produktiven Start von 0.5.2 müssen die Deployments gestoppt, ein
verifiziertes Backup vorhanden und die zwölf Spalten mit
`apps/base/mailman/postgres-schema-repair-052.sql` auf den Typ einer frischen
3.3.10-Datenbank gebracht werden. `AT TIME ZONE 'UTC'` erhält dabei den
Zeitpunkt als naive UTC-Zeit. Anschließend nicht nur den Podstatus prüfen,
sondern alle Runner-Prozesse und Core-Logs beobachten.
