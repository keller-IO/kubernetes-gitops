# ADR 0008 — Gemeinsamer CNPG-Cluster für Monitoring-Tools

- **Status:** Angenommen, Backup offen
- **Datum:** 2026-10-19

## Kontext

Beide Gatus-Instanzen (`status.jit.services`, `status.jit-creatives.de`) liefen
ohne `storage`-Block, also mit dem In-Memory-Store von Gatus. Beim Ausfall von
`kellerio-wrk2` am 19.10.2026 wurden beide Pods neu gestartet, und die gesamte
Uptime-Historie war weg. Auf der öffentlichen Seite fiel das sofort auf.

Kite lag auf SQLite auf einem eigenen RWO-PVC (`Recreate`-Strategie).

Laut Repo-Regel (`apps/AGENTS.md`) ist PostgreSQL über CNPG die erste Wahl. Das
übliche Muster ist ein Cluster pro App mit 2 Instanzen. Für drei kleine Tools,
deren Daten nur „nice to have“ sind, wären das sechs Postgres-Pods.

## Entscheidung

Ein gemeinsamer Cluster `monitoring-pg` im Namespace `monitoring-db`
(`infrastructure/base/monitoring-db/`) für kleine Monitoring- und Betriebstools:

| Datenbank | Rolle | Nutzer | Secret im App-Namespace |
|---|---|---|---|
| `gatus` | `gatus` (initdb-Owner) | Gatus intern | `gatus/gatus-db` |
| `gatus_public` | `gatus_public` (managed role) | Gatus öffentlich | `gatus-public/gatus-public-db` |
| `kite` | `kite` (managed role) | Kite (ab der SQLite-Migration) | `kite/kite-db` |

- Jede App hat ihre eigene Rolle und ist Owner nur ihrer DB. Tabellen anderer
  Rollen sind ohne GRANT nicht lesbar, und unter PG 17 gibt es kein `CREATE` auf
  `public` für fremde Rollen. Das öffentlich erreichbare `gatus-public` sieht
  damit keine Kite-Daten.
- Neue Tools kommen hinzu über: Eintrag in `spec.managed.roles`, Secret
  `monitoring-pg-<app>` (basic-auth, Label `cnpg.io/reload`), ein
  `Database`-CR und eine Kopie des Passworts im App-Namespace.
- Die Passwörter liegen doppelt vor: einmal in `monitoring-db` (für CNPG), einmal
  im jeweiligen App-Namespace (für die App). Wer ein Passwort rotiert, muss beide
  SOPS-Dateien gleich ändern.
- Verbindung über `monitoring-pg-rw.monitoring-db.svc.cluster.local:5432`,
  `sslmode=require`. Im Cluster gibt es keine NetworkPolicies, die das blocken.

## Grenzen

- Was hier hineinkommt, sind kleine Tools mit geringem Schreibvolumen, deren
  Ausfall keinen Kundendienst betrifft. Produktive Fach-Apps (Paperless, Mailman,
  …) behalten ihren eigenen Cluster, damit Wartung, Restore und Versionswechsel
  getrennt bleiben.
- Ein Restore wirkt auf alle drei DBs gleichzeitig (Point-in-Time pro Cluster).
- Ein Postgres-Major-Upgrade gilt für alle Nutzer gleichzeitig.

## Offen: Backup

Der Cluster läuft vorerst **ohne** Garage-S3-Backup. Das S3-Secret kann nur
jemand mit einem SOPS-Empfängerschlüssel aus einem bestehenden Namespace
übernehmen. Ein Platzhalter-Archive-Target würde WALs stauen, bis die Disk voll
ist. Nachziehen: Secret `monitoring-backup-s3` anlegen, dann `backup.barmanObjectStore`
(`s3://backups/cnpg-monitoring/`, 30d) und ein `ScheduledBackup` wie bei
`paperless-ngx`.

## Folgeschritt: Kite

Das Secret `kite/kite-db` liegt bereits vor, Kite läuft aber noch auf SQLite. Die
Übernahme der SQLite-Daten folgt in einem eigenen PR nach dem Muster aus
`docs/learnings/goloom-sqlite-nach-postgres.md` (PreSync-Hooks: App auf 0,
Export/Import mit expliziten Typ-Casts, Abgleich der Zeilenzahlen).
