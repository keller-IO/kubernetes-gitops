# ADR 0008 — Gemeinsamer CNPG-Cluster für Monitoring-Tools

- **Status:** Angenommen (Nachtrag 2026-10-23: `gatus_public` entfällt)
- **Datum:** 2026-10-19

## Kontext

Beide Gatus-Instanzen (`status.jit.services`, `status.jit-creatives.de`) liefen
ohne `storage`-Block, also mit dem In-Memory-Store von Gatus. Beim Ausfall von
`kellerio-wrk2` am 19.10.2026 wurden beide Pods neu gestartet, und die gesamte
Uptime-Historie war weg. Auf der öffentlichen Seite fiel das sofort auf.

Kite lag bis 19.10.2026 auf SQLite auf einem eigenen RWO-PVC (`Recreate`-Strategie).

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
| `kite` | `kite` (managed role) | Kite | `kite/kite-db` |

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

## Backup

Nach dem Schema aus `docs/runbooks/backup-restore.md` bekommt der Cluster einen
eigenen Garage-Bucket `backup-monitoring-db` (Quota 20 GiB) und einen eigenen
Key `backup-monitoring-db`, der nur auf diesem Bucket lesen und schreiben darf.
CNPG archiviert WAL kontinuierlich nach `s3://backup-monitoring-db/cnpg/`
(Retention 30d), dazu kommt täglich um 02:30 ein Base-Backup (`ScheduledBackup`).
Die Zugangsdaten liegen im SOPS-Secret `monitoring-db-backup-s3`. Ein Restore
stellt alle drei Datenbanken gemeinsam wieder her (siehe Konsequenzen).

## Kite: SQLite → Postgres

Umgestellt per ArgoCD-PreSync-Hooks nach dem Goloom-Muster
(`infrastructure/base/kite/migration/`):

- Wave -3: Hook-RBAC und Skript-ConfigMap. Normale Ressourcen entstehen erst
  nach den PreSync-Hooks, deshalb sind auch diese Teile Hooks.
- Wave -2: Kite auf 0 skalieren.
- Wave -1: `kite.db` **read-only** exportieren (`sqlite3 -json`) und in einer
  Transaktion importieren. Das Schema `postgres-schema-v0.16.0.sql` ist das, was
  Kites eigenes AutoMigrate auf Postgres 17.2 erzeugt (`pg_dump --schema-only`).
  Beim nächsten Start ändert AutoMigrate daran nichts, das ist geprüft.
- Spalten werden über den Namen zugeordnet und auf den Postgres-Typ gecastet
  (0/1 → boolean). Zeilenzahl je Tabelle wird geprüft, die Sequenzen werden
  nachgezogen, und die Marker-Tabelle `_kite_sqlite_import` verhindert einen
  zweiten Lauf.
- Secret-Spalten (Cluster-Kubeconfig, LDAP-Bind, OAuth-Secret, MFA, API-Keys)
  sind AES-GCM-Text mit `KITE_ENCRYPT_KEY`. Sie werden 1:1 übernommen, weil der
  Key gleich bleibt.

Lokal getestet: Kite v0.16.0 mit Testdaten auf SQLite, dann Import, danach Kite
auf Postgres gestartet. Logins, Rollenzuweisungen, Entschlüsselung der
Cluster-Config und neue Inserts (Sequenzen) funktionieren.

Die PVC `kite-storage` mit `kite.db` bleibt als Rückfallstand
(`Prune=false,Delete=false`, `infrastructure/base/kite/pvc.yaml`). Rückweg:
den Umstellungs-PR revertieren. Die Hooks werden nach erfolgreicher Umstellung
in einem Folge-PR entfernt.

Nebenwirkung: Plugin-Dateien liegen ohne PVC flüchtig im Container. Offizielle
Plugins lädt Kite anhand der DB-Einträge neu, manuell hochgeladene müssten neu
hochgeladen werden. Die Benutzersuche ist auf Postgres case-sensitiv (`LIKE`).

## Nachtrag 2026-10-23

`status.jit-creatives.de` läuft nicht mehr im Cluster, sondern extern auf
`prometheus.radiotux.de` (Ansible-Rolle `gatus_public` in `jit/ansible`, SQLite
auf dem Host). Die öffentliche Seite soll gerade dann etwas anzeigen, wenn
kellerIO oder der Telekom-Anschluss ausfällt; mit der Datenbank im Cluster ging
das nicht. Rolle und Datenbank `gatus_public` stehen deshalb auf
`ensure: absent`. `monitoring-pg` dient weiter Gatus intern und Kite.
