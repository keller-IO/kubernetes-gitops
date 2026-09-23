# Paperless-ngx: Upgrade von 2.20.15 auf 3.x

Stand: 23.09.2026. Dieses Runbook trennt den verpflichtenden 2.x-Zwischenstand
bewusst vom Major-Upgrade. ArgoCD darf beide Schritte nicht in einem Sync
ueberspringen.

## Zielversionen

- Letztes stabiles 2.x-Release: `2.20.15` vom 27.04.2026.
- Aktuelles stabiles 3.x-Release: `3.2.1` vom 20.09.2026. Der direkte Sprung von
  der nachweislich gelaufenen 2.20.15 auf 3.2.1 ist unterstuetzt; 3.0.x und 3.1.x
  muessen nicht einzeln ausgerollt werden.
- `3.0.1` nicht einsetzen: dessen Datenbankmigration verhindert den Start;
  `3.0.2` enthaelt die Korrektur.
- Versionen bis einschliesslich `3.1.1` nicht einsetzen: `3.1.2` schliesst die
  Path-Traversal-Luecke GHSA-2jhj-xqrq-rmrq. `3.2.0` ist durch 3.2.1 ersetzt;
  3.2.1 repariert unter anderem die automatische Tantivy-Neuerstellung bei
  fehlenden Indexdateien.
- Das Helm-Chart `gabe565/paperless-ngx` ist bereits auf dem aktuellen Stand
  `0.24.1`. Sein veraltetes `appVersion: 2.14.7` beeinflusst nur Labels;
  `image.tag` steuert das tatsaechliche Image. Ein Chart-Bump ist nicht noetig.

## Planstatus

| Phase | Status | Naechster Schritt |
|---|---|---|
| 1: 2.20.15 | Abgeschlossen | Export und PVC-Snapshots vom 02.08. behalten; das damalige CNPG-Backup ist abgelaufen |
| Stabilisierung | Blockiert | Wiederholte Celery-Child-Start-Timeouts auf 2.20.15 erklaeren und beseitigen |
| 2: 3.x-Recovery-Punkt | Offen | Erst nach stabiler 2.20.15 einen neuen quieszierten Export, CNPG-Backup und Snapshots erzeugen |
| 3: 3.x-Change | Offen | Separater PR auf die dann aktuelle gepruefte 3.x-Patchversion, derzeit 3.2.1 |
| Abnahme | Offen | Migration, Tantivy-Aufbau, OIDC, OCR, Suche, Mail und SMB-Consume pruefen |

## Gepruefter Ist-Stand

Am 23.09.2026 wurden Repository, gerendertes Manifest und Cluster read-only
geprueft:

| Bereich | Ergebnis |
|---|---|
| Laufende App | `2.20.15`, Deployment `1/1`; aktueller Pod seit 32 Tagen ohne Container-Restart |
| GitOps | `app-paperless-ngx` ist `Synced` und `Healthy`; PR #89 ist gemergt |
| Datenbank | CNPG/PostgreSQL 17.2, Cluster gesund; PostgreSQL >=14 wird von Paperless 3 unterstuetzt |
| Backup | Taegliche CNPG-Backups laufen; `paperless-pg-20260923020000` ist `completed`. Sie ersetzen kein Backup der Paperless-PVCs oder der externen Scanner-Inbox |
| Broker | Valkey 8.1 ueber `redis://paperless-valkey:6379`, kompatibel |
| Secret | `PAPERLESS_SECRET_KEY` ist im SOPS-Secret vorhanden und muss unveraendert bleiben |
| DB-Konfiguration | `PAPERLESS_DBENGINE=postgresql` ist bereits explizit gesetzt; keine veralteten erweiterten DB-Variablen im Manifest |
| Volumes | `data`, `media` und `export` liegen auf RBD-PVCs; `consume` bindet `//192.168.2.75/scanner` per SMB-CSI ein |
| Rollout | Eine Replica und Strategie `Recreate`; keine parallelen App-Migrationen |
| CPU | Alle Worker haben `pni`, `ssse3`, `sse4_1`, `sse4_2`, `popcnt` und `cx16`; NumPys `x86-64-v2`-Minimum ist erfuellt |
| Chart-Ressourcen | Kein HPA; Redis-Subchart bleibt deaktiviert |
| Verschluesselung | Keine `.gpg`-Dateien im Media-PVC gefunden; keine Passphrase oder Consume-Skripte im Deployment konfiguriert |
| Export-Platz | 1,9 GiB frei; Media-PVC derzeit nur 42 MiB belegt |
| Ressourcen | Messpunkt vom 23.09.2026: 890 MiB von 1536 MiB Container-Limit; Cgroup meldet 229 `memory.max`-Ereignisse, aber keine `oom_kill`-Ereignisse |
| Offener Fehler | 40 Celery-Child-Prozesse meldeten in den letzten sieben Tagen nicht rechtzeitig `WORKER_UP` und wurden danach als per `SIGKILL` beendet protokolliert; der Hauptprozess lief weiter |

### Historische Phase-1-Artefakte vom 02.08.2026

Paperless 2.20.6 war fuer alle folgenden Sicherungen auf null Replicas skaliert;
die Scanner-Inbox war leer:

| Artefakt | Wert |
|---|---|
| Paperless-Export | 48 Dokumente; lokales Archiv `/home/ingo/ansible/backups/paperless-pre-2.20.15-20260802.tar.gz`, 45 MiB |
| Export SHA-256 | `590ad83f243baae66f08681a824586de3b426d922381cc23d7d0d68268dc4650` |
| CNPG-Backup | `paperless-pg-pre-22015-20260802`; Barman-ID `20260802T171946`; WAL `000000010000000F00000017`; durch die 30-Tage-Retention seit ca. 01.09.2026 geloescht |
| Data-Snapshot | `paperless-data-pre-22015-20260802`; Content `snapcontent-8fd96659-0375-4e0f-a8a8-f3b01603b9db` |
| Media-Snapshot | `paperless-media-pre-22015-20260802`; Content `snapcontent-81bea0d7-b40f-403b-bded-19fdb3db30c7` |

Export-Manifest und Datenbank enthielten beide exakt 48 Dokumente. Die beiden
`VolumeSnapshot`-Objekte bleiben bis nach der 3.x-Abnahme deklarativ erhalten.
Da das Barman-Backup abgelaufen ist, bilden diese Artefakte heute **keinen
vollstaendigen, punktgenauen Rollback** auf den damaligen Datenbankstand mehr.
Der Export ist ein separat zu testender logischer Datenrettungsweg; die
Snapshots sichern nur die damaligen Dateien.

Vor dem Major-Upgrade trotzdem manuell zu bestaetigen:

- Es gibt auch in extern eingebundenen oder nicht im Deployment sichtbaren
  Pre-/Post-Consume-Skripten keine Positionsparameter `$1` bis `$8`. Falls doch,
  auf die dokumentierten `DOCUMENT_*`-Umgebungsvariablen umstellen.
- Wichtige gespeicherte Suchen, die unqualifiziert Notizen oder Custom Fields
  durchsuchen, sind erfasst.
- Der vollstaendige 2.20.15-Export laeuft erfolgreich durch und wird ausserhalb
  des Cluster-Ceph gesichert.

## Phase 1: 2.20.15 ausrollen (abgeschlossen)

PR [#89](https://github.com/keller-IO/kubernetes-gitops/pull/89) wurde am
02.08.2026 gemergt. Das Image `2.20.15` laeuft produktiv; ArgoCD meldet die App
am 23.09.2026 als `Synced` und `Healthy`. Der aktuelle Pod ist `Ready`, hat keine
Container-Restarts und verarbeitet Mail-, Workflow-, Index- und
Classifier-Aufgaben. Damit ist die von Paperless 3 verlangte 2.20.15-Migration
tatsaechlich ausgefuehrt und nicht nur in Git vorhanden.

Die Snapshots und der Export vom 02.08. bleiben als historische
Wiederherstellungsartefakte erhalten. Das zugehoerige Barman-Backup wurde durch
die 30-Tage-Retention geloescht; ein deterministischer Restore des damaligen
2.20.6-Gesamtstands ist daher nicht mehr moeglich. Sie sind wegen der seitdem
erfolgten produktiven Aenderungen ohnehin **nicht** der Recovery-Punkt fuer das
3.x-Upgrade; Phase 2 erzeugt dafuer neue Artefakte.

Paperless 3 prueft die 2.20.15-Migrationen und verweigert einen direkten Sprung
von 2.20.6.

### Phase-1-Abnahme vom 02.08.2026

- ArgoCD: `Synced`, `Healthy`, Operation `Succeeded` auf Merge-Commit
  `dc3b7e4b370f28e3e5b63e96b58131aafd8db72f`.
- Paperless meldet beim Start `v2.20.15`; keine ausstehenden Migrationen und
  `System check identified no issues`.
- Deployment `1/1`, keine Pod-Restarts; PostgreSQL und Valkey gesund.
- Oeffentliche Login-Seite HTTP 200 und Keycloak-OIDC-Schaltflaeche vorhanden.
- SMB-Polling aktiv. `BRN94DDF86F11BA_000103.pdf` und
  `BRN94DDF86F11BA_000105.pdf` wurden erfolgreich konsumiert; die Inbox ist
  danach leer und die Datenbank enthaelt 50 Dokumente.
- Interaktiven Keycloak-Login, Dokumentanzeige und Suche vor dem 3.x-Preflight
  noch einmal mit einem Benutzerkonto bestaetigen.

## Stabilitaets-Gate vor 3.x

Das Major-Upgrade bleibt blockiert, bis die Celery-Worker auf 2.20.15 stabil
sind. In den Logs vom 21. bis 23.09.2026 meldeten sich 40 neu gestartete
Child-Prozesse nicht innerhalb von Celerys standardmaessigem
`worker_proc_alive_timeout` von vier Sekunden mit `WORKER_UP`. Im selben
Fehlerablauf wurden sie als per `SIGKILL` beendet protokolliert; Ursache und
Signalgeber sind noch zu belegen. Der Container wurde nicht neu gestartet.
`memory.events` zeigt keine Cgroup-OOM-Kills, aber 229 `max`-Ereignisse am
1536-MiB-Limit.

1. Die `Timed out waiting for UP message`-Zeitpunkte mit CPU-Throttling,
   Node-Speicherdruck, Kernel-/Talos-Logs, Cgroup-`memory.current`/`memory.peak`/
   `memory.events`, I/O-Wartezeit und den jeweils gestarteten Paperless-Tasks
   korrelieren.
2. Spitzenverbrauch und Child-Startzeit waehrend Mailabruf, Workflow-Checks,
   Classifier-Training und OCR messen. Requests/Limits nicht schaetzen, sondern
   aus diesen Messungen ableiten.
3. Paperless verwendet ohne `PAPERLESS_TASK_WORKERS` bereits den Default von
   einem Worker. Eine niedrigere Task-Parallelitaet deshalb nicht als Loesung
   voraussetzen; zuerst die tatsaechliche Worker-/Thread-Konfiguration im
   gerenderten Deployment und im Startlog erfassen.
4. Die belegte Ursache in einem separaten Stabilitaets-PR beheben, etwa durch ein
   gemessenes Ressourcenbudget. Ein laengerer Start-Timeout allein kaschiert
   Ressourcen- oder I/O-Stalls und ist kein Stabilitaetsnachweis.
5. Danach mindestens sieben Tage ohne `Timed out waiting for UP message`
   beobachten. Erst dann Phase 2 starten. Der erste 3.x-Start mit Migration und
   Tantivy-Neuaufbau darf nicht auf eine bereits instabile Worker-Situation
   aufsetzen.

## Phase 2: Backup- und Preflight-Gate

Vor dem ersten Start von 3.x keine neuen Dokumente konsumieren und keine
Metadaten aendern. Ein leerer Queue-Stand allein ist keine Schreibsperre.

1. Vor Beginn ein Wartungsfenster durchsetzen: schreibende UI-/API-Zugriffe
   sperren, Scanner und andere Produzenten anhalten sowie Mailabruf, Workflows
   und geplante Consumer-Aufgaben pausieren. Danach Celery-/Consume-Warteschlange
   leerlaufen lassen und den weiterhin leeren Zustand kontrollieren.
2. Noch nicht verarbeitete Dateien aus `//192.168.2.75/scanner` separat sichern.
   Die SMB-Inbox ist kein Ceph-PVC und wird von `VolumeSnapshot`s nicht erfasst.
3. Unter laufendem `2.20.15`, aber innerhalb der erzwungenen Schreibsperre,
   einen vollstaendigen Paperless-Export erzeugen, aus dem Cluster-Ceph kopieren
   und Inhalt sowie SHA-256 pruefen. Exporte sind versionsgebunden; dieser Export
   ist der logische Rueckweg zu 2.20.15.
4. Den schreibenden Paperless-Pod ueber einen separaten GitOps-Schritt stoppen
   und auf sein Verschwinden sowie das Loesen seiner `VolumeAttachment`s warten.
   Postgres bleibt fuer sein natives Backup aktiv.
5. Vor dem Backup die Barman-Retention per GitOps fuer die gesamte Rollbackfrist
   auf mindestens 90 Tage erhoehen oder Base-Backup und benoetigte WALs in ein
   separates, nicht von der 30-Tage-Retention verwaltetes Ziel kopieren. Die
   laengere Retention erst nach abgeschlossener 3.x-Abnahme oder bewusstem
   Verzicht auf Rollback zuruecknehmen.
6. Ein neues CNPG-Base-Backup inklusive funktionierendem WAL-Archiv erzeugen und
   verifizieren. Danach `VolumeSnapshot`s fuer `data` und `media` erzeugen. Da
   Paperless seit Schritt 4 gestoppt ist, gehoeren Datenbank, PVCs und die
   separate Kopie der Scanner-Inbox zum selben quieszierten Anwendungsstand. Das
   Snapshot-Verfahren steht in `docs/runbooks/backup-restore.md`.
7. Nach Abschluss aller Sicherungen, aber vor dem ersten 3.x-Start, mit
   `pg_create_restore_point` einen eindeutig benannten PostgreSQL-Restore-Punkt
   anlegen und danach mit `pg_switch_wal` den Segmentwechsel erzwingen. Notieren:
   Restore-Punkt, Kubernetes-Backup-Name, `Backup.status.backupId` (Barman-ID),
   Snapshot-Namen sowie Ort, SHA-256 und Zeitstempel der Export- und
   Scanner-Inbox-Sicherung. Bestaetigen, dass das WAL mit dem Restore-Punkt im
   geschuetzten Ziel archiviert wurde. Kubernetes-Name und Barman-ID sind nicht
   austauschbar.
8. Das Rollback-Ziel **vor dem Upgrade echt testen**: einen temporaeren CNPG-
   Cluster mit genau dieser Barman-ID und `targetName` restaurieren und
   Dokument-/Benutzerzahlen pruefen. Aus beiden Snapshots Wegwerf-PVCs erzeugen,
   mounten und exemplarische Dateien lesen; Schreib-/Loeschproben nur auf den
   Restore-PVCs ausfuehren. Namen, Ergebnis und Logs als Abnahmeevidenz
   festhalten. Ohne erfolgreichen Restore-Test kein Major-Upgrade.
9. Die drei oben genannten manuellen Punkte pruefen: externe Consume-Skripte,
   gespeicherte Suchen und den vollstaendigen Export.

Nur das CNPG-Backup reicht nicht: Dokumente und Such-/Classifier-Daten liegen
auch auf RBD-PVCs. Ein reiner Image-Downgrade nach ausgefuehrten 3.x-Migrationen
ist kein gueltiger Rollback.

## Phase 3: Separater 3.x-Change

In einem neuen PR nach bestandenem Stabilitaets- und Backup-Gate:

1. `image.tag` auf die dann aktuelle, gepruefte 3.x-Patchversion setzen. Stand
   23.09.2026 ist das `3.2.1`; vor dem PR Releases erneut pruefen.
2. Wegen der SMB-Inbox `PAPERLESS_CONSUMER_POLLING` zwingend in
   `PAPERLESS_CONSUMER_POLLING_INTERVAL` umbenennen und den Wert `"10"`
   beibehalten. Der alte Name wird von 3.x nicht mehr ausgewertet.
3. `PAPERLESS_OCR_MODE` von `skip` auf `auto` aendern.
4. `PAPERLESS_ARCHIVE_FILE_GENERATION=always` setzen, um das bisherige Verhalten
   von `skip` beizubehalten: OCR bei vorhandenem Text ueberspringen, aber immer
   eine Archivdatei erzeugen.
5. Entscheiden, ob das bisherige Ablehnen von Duplikaten erhalten bleiben soll.
   Falls ja, `PAPERLESS_CONSUMER_DELETE_DUPLICATES="true"` setzen; 3.x erlaubt
   Duplikate standardmaessig.
6. Das Startup-Probe-Budget von derzeit 150 Sekunden fuer den ersten Rollout auf
   mindestens zehn Minuten erhoehen. Beim ersten 3.x-Start wird der inkompatible
   Whoosh-Index automatisch als Tantivy-Index neu aufgebaut. Nach der Abnahme
   anhand der gemessenen Startzeit wieder enger setzen.
7. Den unter dem Stabilitaets-Gate ermittelten Ressourcen-/Worker-Wert
   beibehalten; insbesondere das heutige 1536-MiB-Limit nicht ungeprueft fuer
   Migration und Index-Neuaufbau voraussetzen.
8. Manifest rendern und kontrollieren: genau eine App-Replica, `Recreate`, kein
   HPA, unveraenderte Storage-Mounts und alle Env-Werte am richtigen Namen.
9. `nix develop -c just validate` ausfuehren und den Change separat mergen.

## Beobachtung und Abnahme

Beim ersten 3.x-Sync:

1. Logs bis zum Abschluss von Datenbankmigration und Suchindex-Neuaufbau
   beobachten. Erhoehte CPU-, RAM- und I/O-Last ist dabei erwartbar.
2. Pod-Restarts, OOMKills, `SIGILL` und Probe-Fehler ausschliessen.
3. Admin- und Keycloak-Login testen. Bei OIDC `invalid_client` im Provider-JSON
   `settings.token_auth_method`, typischerweise `client_secret_basic`, setzen.
4. Bei Login-HTTP-403 die reale `X-Forwarded-For`-Kette pruefen und erst danach
   `PAPERLESS_TRUSTED_PROXIES`, `PAPERLESS_ALLAUTH_TRUSTED_PROXY_COUNT` oder
   `PAPERLESS_ALLAUTH_TRUSTED_CLIENT_IP_HEADER` konfigurieren.
5. Dokumentanzeige, Download, Suche, OCR, Consume und Mail-Regeln testen.
6. OCR-Konfiguration in der Admin-Oberflaeche pruefen. DB-gespeicherte Werte
   werden migriert, Env-Werte haben jedoch Vorrang.
7. Erwartete Datenwirkung bestaetigen: Die bestehende Task-Historie wird bei der
   Migration geloescht; der Dokumentbestand darf sich nicht aendern.

## Rollback

Nach dem ersten 3.x-Start nicht nur den Image-Tag zuruecksetzen. Stattdessen:

1. Paperless per GitOps auf null Replicas halten und weitere Writes verhindern.
2. CNPG restauriert nicht in-place: Nach `docs/runbooks/backup-restore.md` einen
   neuen Cluster aus dem dokumentierten Backup erstellen. Unter
   `recoveryTarget` sind sowohl `backupID` mit der notierten Barman-ID als auch
   `targetName` mit dem gemeinsamen PostgreSQL-Restore-Punkt zwingend zu setzen;
   sonst kann CNPG ein spaeteres Backup waehlen, von dem der Restore-Punkt nicht
   erreichbar ist. Paperless per GitOps auf den neuen `-rw`-Service umstellen.
3. Neue PVCs aus den dazugehoerigen Snapshots von `data` und `media` erzeugen
   und die Paperless-Manifeste auf diese Restore-Claims umstellen. Die
   Original-Claims bis zur abgeschlossenen Konsistenzpruefung nicht loeschen.
4. Valkey gestoppt halten und seinen persistenten AOF-Datentraeger durch einen
   leeren Restore-PVC ersetzen. Keine 3.x-Queue-Nachrichten duerfen gegen die
   restaurierte 2.20.15-Datenbank laufen.
5. Image und den vollstaendigen 2.20.15-Konfigurationsstand wiederherstellen:
   `PAPERLESS_CONSUMER_POLLING_INTERVAL` zurueck in
   `PAPERLESS_CONSUMER_POLLING="10"` umbenennen,
   `PAPERLESS_OCR_MODE=skip` setzen, die nur fuer 3.x ergaenzten
   `PAPERLESS_ARCHIVE_FILE_GENERATION`- und gegebenenfalls
   `PAPERLESS_CONSUMER_DELETE_DUPLICATES`-Werte entfernen und das vorherige
   Startup-Probe-Budget wiederherstellen. Denselben `PAPERLESS_SECRET_KEY`
   behalten.
6. Zuerst Postgres, dann leeres Valkey und zuletzt Paperless starten. Erst nach
   Konsistenzpruefung den Dienst wieder freigeben und danach gesicherte,
   unvollstaendig konsumierte Scanner-Dateien kontrolliert in die SMB-Inbox
   zuruecklegen.

Ein punktgenauer Rollback des Phase-1-Upgrades auf 2.20.6 ist nicht mehr
moeglich, weil das zugehoerige Barman-Backup abgelaufen ist. Im Notfall den
Export vom 02.08. in einer isolierten, leeren 2.20.6-Instanz testweise
importieren und die beiden Snapshots separat zur Dateirettung mounten. Diese
logische Rekonstruktion nicht als Restore des damaligen Gesamtstands behandeln.

## Quellen

- [Paperless-ngx 2.20.15](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v2.20.15)
- [Offizieller v3-Migrationsleitfaden](https://github.com/paperless-ngx/paperless-ngx/blob/v3.2.1/docs/migration-v3.md)
- [Paperless-ngx 3.2.1](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v3.2.1)
- [Warnung zu 3.0.1](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v3.0.1)
- [Security Advisory GHSA-2jhj-xqrq-rmrq](https://github.com/paperless-ngx/paperless-ngx/security/advisories/GHSA-2jhj-xqrq-rmrq)
- [Paperless Backup und Export](https://github.com/paperless-ngx/paperless-ngx/blob/v3.2.1/docs/administration.md#backup)
- [Celery 5.5: `worker_proc_alive_timeout`](https://docs.celeryq.dev/en/v5.5.3/userguide/configuration.html#worker-proc-alive-timeout)
- [Helm-Chart 0.24.1](https://github.com/gabe565/charts/blob/main/charts/paperless-ngx/Chart.yaml)
- [CNPG 1.25: Recovery Targets](https://cloudnative-pg.io/docs/1.25/recovery#recovery-targets)
