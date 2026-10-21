# MariaDB-Server-Upgrade 11.4 → 11.8 → 12.3 (LTS)

Stand: 2026-10-21.

## Ausgangslage

- Fünf Standalone-Instanzen (`replicas: 1`, kein Galera) über mariadb-operator
  26.10.1: `kimai`, `matomo`, `wordpress-1/2/3`, alle auf `mariadb:11.4.5`.
- Renovate schlug `11.4.5 → 13.0.2` vor (#348–#350). 13.0 ist ein
  Short-Term-Release mit Community-EOL Q4 2026. Ziel ist stattdessen die
  LTS-Linie 12.3 (EOL 2029), in zwei Stufen über 11.8 (EOL 2028).
- Renovate darf seitdem nur noch Patches innerhalb einer Linie vorschlagen
  (`renovate.json`, Regel „MariaDB: patch updates within the current LTS line").

## Was zählt

| Thema | Folge |
|---|---|
| Major-Downgrade nicht unterstützt | Rollback = Restore eines Dumps in eine **frische Instanz derselben alten Version** |
| Ohne `updateStrategy.mariadbAutoUpgradeEnabled: true` | Server startet auf neuer Version, `mariadb-upgrade` läuft nicht; `healthcheck.sh` und damit Ready bleiben trotzdem grün — kein Signal |
| Backup-Job nutzt `spec.image` der MariaDB als Dump-Client (Init-Container) | Pre-Upgrade-Dump muss **vor** dem Image-Bump laufen |
| Operator-Dump ist `--all-databases` inkl. Schema `mysql` | Restore eines 11.4-Dumps in 12.3 scheitert (`ERROR 1805 Column count of mysql.proc`); nur in gleiche Version zurückspielen |
| `my.cnf` setzt Charset/Collation explizit | Default-Wechsel auf `utf8mb4_uca1400_ai_ci` (11.8) greift nicht |
| 11.8: `innodb_snapshot_isolation` | stale Snapshots können `ERROR 1020 Record has changed since last read` werfen — App-Logs prüfen |
| 12.3: neue reservierte Wörter `CONVERSION`, `TO_DATE` | App-Logs auf Syntaxfehler prüfen |

Generalprobe am 21.10.2026 auf Podman (Kind rootless nicht verfügbar):
11.4.5 → 11.8.9 → 12.3.3 auf demselben Datadir mit `MARIADB_AUTO_UPGRADE=1`;
Checksumme, View, Prozedur, Trigger und Login unverändert; Restore des
11.4-Dumps in frische 11.4.5 vollständig.

## Live-Befunde Stufe 1 (11.4.5 → 11.8.9, 21.10.2026)

Abgeschlossen: kimai (#360), matomo (#361), wordpress-1/2/3 (#362).


- **Downtime 3–8 min je Instanz** (kimai 8 min, matomo 3,5 min). Fast alles
  steckt in Phase 3 `mysql_fix_privilege_tables` (ALTERs auf `mysql.*`, Ceph-RBD),
  unabhängig von der Größe der App-Daten. Apps loggen in dem Fenster
  `SQLSTATE[HY000] [2002] Connection refused`.
- **`Ready` lügt während des Upgrades:** Der Entrypoint startet einen temporären
  Server mit `skip_networking=ON`. `healthcheck.sh` geht über den Socket, Pod und
  MariaDB-CR melden `Ready`, die App erreicht aber Port 3306 nicht. Fertig ist es
  erst bei `Finished mariadb-upgrade` und danach `Version: '<ziel>' … port: 3306`.
- Beim Wechsel vom temporären zum finalen Server schlagen Readiness- **und
  Liveness**-Probe einmal fehl (`ERROR 2002 … mysqld.sock`). Bei allen fünf
  Instanzen ohne Neustart; dauert Phase 3 deutlich länger als 8 min, die
  Liveness-Toleranz vorher prüfen.
- wordpress-3 (`site3.jit.services`) ist bewusst auf 0 Replicas — 502 dort ist
  kein Upgrade-Befund.
- `[ERROR] Invalid (old?) table or database name 'lost+found'` stammt vom
  ext4-Root des PVC (Datadir) und tritt bei jedem Dump auf — harmlos.
- `matomo.jit.services` löst lokal ggf. auf `0.0.0.0` auf (Tracker-Blocker im
  DNS); zum Prüfen `curl --resolve matomo.jit.services:443:192.168.2.246`.

## Ablauf je Stufe

Reihenfolge: **kimai** (Canary) → **matomo** → **wordpress-1/2/3** (gemeinsame Base).

1. **PR Backup:** One-Shot-`Backup` `<app>-mariadb-pre-upgrade-<ziel>`
   (`apps/base/<app>/pre-upgrade-backup.yaml`, eigener Prefix
   `mariadb-<app>[-N]-pre-upgrade-<ziel>`, 90d Retention). Nach dem Sync:
   ```bash
   kubectl get backup.k8s.mariadb.com -A | grep pre-upgrade   # COMPLETE True / Success
   ```
2. **PR Upgrade (pro App):** in `database.yaml` `updateStrategy.mariadbAutoUpgradeEnabled: true`
   (bleibt dauerhaft, beim Neustart ohne Versionswechsel ein No-op) und `spec.image`
   auf die Zielversion. Kimai: `serverVersion` in `DATABASE_URL` angleichen.
3. **Prüfen nach dem Sync:**
   ```bash
   kubectl -n <ns> logs <app>-mariadb-0 -c mariadb | grep -E 'upgrade|ERROR'
   #   erwartet: "Major version upgrade detected from 11.4.5-MariaDB to 11.8.9-MariaDB"
   #             "Finished mariadb-upgrade", danach "Version: '11.8.9…' port: 3306"
   kubectl -n <ns> exec <app>-mariadb-0 -c mariadb -- sh -c \
     'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -Nse "SELECT VERSION()"; \
      mariadb-upgrade -uroot -p"$MARIADB_ROOT_PASSWORD" --check-if-upgrade-is-needed; echo rc=$?'
   #   rc=1 = kein Upgrade mehr nötig
   kubectl get mariadb -A   # Ready True — allein KEIN Beleg, siehe Live-Befunde
   ```
   App-Login und App-Logs prüfen (Kimai, Matomo-Archivierung, WordPress-Frontend).
   Nächster Backup-Lauf (02:00 bzw. 02:30) muss `Success` melden.
4. Erst dann die nächste App bzw. Stufe.

## Rollback

Downgrade auf demselben PVC ist nicht unterstützt. Stattdessen:

1. `spec.image` per Revert zurück auf die alte Version **und** PVC verwerfen
   (MariaDB-CR löschen lassen bzw. PVC `storage-<app>-mariadb-0` entfernen —
   braucht explizite Schreibfreigabe).
2. Frische Instanz auf der alten Version starten lassen.
3. `Restore`-CR aus dem Pre-Upgrade-Prefix (siehe `backup-restore.md`,
   Abschnitt „MariaDB-Restore"), `s3.prefix: mariadb-<app>-pre-upgrade-<ziel>`.

## Aufräumen

Nach erfolgreicher Stufe `pre-upgrade-backup.yaml` aus Git entfernen
(ArgoCD pruned das CR). Der Dump bleibt im Bucket, bis er manuell gelöscht wird — ein One-Shot-Backup läuft nie wieder und wendet seine Retention daher nicht an.
