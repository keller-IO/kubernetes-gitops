# Paperless-ngx: Upgrade von 2.20.15 auf 3.x

Stand: 02.08.2026. Dieses Runbook trennt den verpflichtenden 2.x-Zwischenstand
bewusst vom Major-Upgrade. ArgoCD darf beide Schritte nicht in einem Sync
ueberspringen.

## Zielversionen

- Letztes stabiles 2.x-Release: `2.20.15` vom 27.04.2026.
- Aktuelles stabiles 3.x-Release: `3.0.4` vom 28.07.2026.
- `3.0.1` nicht einsetzen: dessen Datenbankmigration verhindert den Start;
  `3.0.2` enthaelt die Korrektur.
- Das Helm-Chart `gabe565/paperless-ngx` ist bereits auf dem aktuellen Stand
  `0.24.1`. Sein veraltetes `appVersion: 2.14.7` beeinflusst nur Labels;
  `image.tag` steuert das tatsaechliche Image. Ein Chart-Bump ist nicht noetig.

## Gepruefter Ist-Stand

Am 02.08.2026 wurden Repository, gerendertes Manifest und Cluster read-only
geprueft:

| Bereich | Ergebnis |
|---|---|
| Laufende App | `2.20.6`, Deployment `1/1`, Pod ohne Restarts |
| Datenbank | CNPG/PostgreSQL 17.2, Cluster gesund; PostgreSQL >=14 wird von Paperless 3 unterstuetzt |
| Backup | CNPG-Backup vom 02.08. `completed`; ersetzt kein Backup der Paperless-PVCs oder der externen Scanner-Inbox |
| Broker | Valkey 8.1 ueber `redis://paperless-valkey:6379`, kompatibel |
| Secret | `PAPERLESS_SECRET_KEY` ist im SOPS-Secret vorhanden und muss unveraendert bleiben |
| DB-Konfiguration | `PAPERLESS_DBENGINE=postgresql` ist bereits explizit gesetzt; keine veralteten erweiterten DB-Variablen im Manifest |
| Volumes | `data`, `media` und `export` liegen auf RBD-PVCs; `consume` bindet `//192.168.2.75/scanner` per SMB-CSI ein |
| Rollout | Eine Replica und Strategie `Recreate`; keine parallelen App-Migrationen |
| CPU | Alle Worker haben `pni`, `ssse3`, `sse4_1`, `sse4_2`, `popcnt` und `cx16`; NumPys `x86-64-v2`-Minimum ist erfuellt |
| Chart-Ressourcen | Kein HPA; Redis-Subchart bleibt deaktiviert |
| Verschluesselung | Keine `.gpg`-Dateien im Media-PVC gefunden; keine Passphrase oder Consume-Skripte im Deployment konfiguriert |
| Export-Platz | 1,9 GiB frei; Media-PVC derzeit nur 42 MiB belegt |

Vor dem Major-Upgrade trotzdem manuell zu bestaetigen:

- Es gibt auch in extern eingebundenen oder nicht im Deployment sichtbaren
  Pre-/Post-Consume-Skripten keine Positionsparameter `$1` bis `$8`. Falls doch,
  auf die dokumentierten `DOCUMENT_*`-Umgebungsvariablen umstellen.
- Wichtige gespeicherte Suchen, die unqualifiziert Notizen oder Custom Fields
  durchsuchen, sind erfasst.
- Der vollstaendige 2.20.15-Export laeuft erfolgreich durch und wird ausserhalb
  des Cluster-Ceph gesichert.

## Phase 1: 2.20.15 ausrollen

Dieser Schritt ist mit dem Image-Pin in `apps/base/paperless-ngx/values.yaml`
vorbereitet. Er muss separat gemergt und von ArgoCD synchronisiert werden.

1. Vor dem ArgoCD-Sync die Warteschlange leerlaufen lassen und einen
   vollstaendigen 2.20.6-Export ausserhalb des Clusters sichern. Fuer einen
   deterministischen Rollback danach den App-Pod stoppen, ein frisches
   CNPG-Backup erstellen und Snapshots von `data` und `media` erzeugen. Noch
   nicht konsumierte Dateien der SMB-Scanner-Inbox separat sichern. Alle
   Sicherungen muessen zum gestoppten Anwendungsstand gehoeren.
2. ArgoCD-Sync fuer `app-paperless-ngx` abwarten.
3. Pruefen, dass das Deployment das Image `2.20.15` verwendet und der Pod
   `Ready` wird.
4. In den Startlogs erfolgreiche Django-Migrationen und keine Migration- oder
   System-Check-Fehler bestaetigen.
5. Web-Login, Keycloak-OIDC, Dokumentanzeige, Suche und einen kontrollierten
   Dokumentimport testen.
6. Erst danach den separaten 3.x-Change vorbereiten. Ein Git-Commit mit
   `2.20.15`, den ArgoCD nie ausgefuehrt hat, erfuellt die Voraussetzung nicht.

Paperless 3 prueft die 2.20.15-Migrationen und verweigert einen direkten Sprung
von 2.20.6.

## Phase 2: Backup- und Preflight-Gate

Vor dem ersten Start von 3.x keine neuen Dokumente konsumieren und keine
Metadaten aendern.

1. Lass die Celery-/Consume-Warteschlange leerlaufen und sichere noch nicht
   verarbeitete Dateien aus `//192.168.2.75/scanner` separat. Die SMB-Inbox ist
   kein Ceph-PVC und wird von `VolumeSnapshot`s nicht erfasst.
2. Erzeuge unter laufendem `2.20.15` einen vollstaendigen Paperless-Export und
   kopiere ihn aus dem Cluster-Ceph. Pruefe dessen Inhalt. Exporte sind
   versionsgebunden; dieser Export ist der Rueckweg zu 2.20.15.
3. Stoppe den schreibenden Paperless-Pod ueber einen separaten GitOps-Schritt
   und warte, bis er vollstaendig beendet ist. Postgres bleibt fuer sein natives
   Backup aktiv.
4. Erzeuge und verifiziere jetzt ein neues CNPG-Base-Backup inklusive
   funktionierendem WAL-Archiv. Erzeuge danach `VolumeSnapshot`s fuer `data` und
   `media`. Da Paperless seit Schritt 3 gestoppt ist, gehoeren Datenbank, PVCs
   und die separate Kopie der Scanner-Inbox zum selben quieszierten
   Anwendungsstand. Das Snapshot-Verfahren steht in
   `docs/runbooks/backup-restore.md`.
5. Lege nach Abschluss aller Sicherungen, aber vor dem ersten 3.x-Start, mit
   `pg_create_restore_point` einen eindeutig benannten PostgreSQL-Restore-Punkt
   an und erzwinge danach mit `pg_switch_wal` den Segmentwechsel. Notiere
   Restore-Punkt, Kubernetes-Backup-Name, `Backup.status.backupId` (Barman-ID)
   und Snapshot-Namen sowie Ort und Zeitstempel der Scanner-Inbox-Sicherung und
   bestaetige, dass das WAL mit dem Restore-Punkt archiviert wurde.
   Kubernetes-Name und Barman-ID sind nicht austauschbar. Dies ist das gemeinsame
   Rollback-Ziel. Ohne getesteten Restore-Punkt kein Major-Upgrade.
6. Pruefe die drei oben genannten manuellen Punkte: externe Consume-Skripte,
   gespeicherte Suchen und den vollstaendigen Export.

Nur das CNPG-Backup reicht nicht: Dokumente und Such-/Classifier-Daten liegen
auch auf RBD-PVCs. Ein reiner Image-Downgrade nach ausgefuehrten 3.x-Migrationen
ist kein gueltiger Rollback.

## Phase 3: Separater 3.x-Change

In einem neuen PR nach erfolgreich laufendem 2.20.15:

1. `image.tag` auf die dann aktuelle, gepruefte 3.0.x-Patchversion setzen,
   mindestens `3.0.4`; niemals `3.0.1`.
2. `PAPERLESS_OCR_MODE` von `skip` auf `auto` aendern.
3. `PAPERLESS_ARCHIVE_FILE_GENERATION=always` setzen, um das bisherige Verhalten
   von `skip` beizubehalten: OCR bei vorhandenem Text ueberspringen, aber immer
   eine Archivdatei erzeugen.
4. Entscheiden, ob das bisherige Ablehnen von Duplikaten erhalten bleiben soll.
   Falls ja, `PAPERLESS_CONSUMER_DELETE_DUPLICATES="true"` setzen; 3.x erlaubt
   Duplikate standardmaessig.
5. Das Startup-Probe-Budget von derzeit 150 Sekunden anhand der Dokumentanzahl
   erhoehen. Beim ersten 3.x-Start wird der inkompatible Whoosh-Index automatisch
   als Tantivy-Index neu aufgebaut.
6. Manifest rendern und kontrollieren: genau eine App-Replica, `Recreate`, kein
   HPA, unveraenderte Storage-Mounts und alle Env-Werte am richtigen Namen.
7. `nix develop -c just validate` ausfuehren und den Change separat mergen.

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
5. Image und 2.20.15-kompatible OCR-Konfiguration wiederherstellen; denselben
   `PAPERLESS_SECRET_KEY` behalten.
6. Zuerst Postgres, dann leeres Valkey und zuletzt Paperless starten. Erst nach
   Konsistenzpruefung den Dienst wieder freigeben und danach gesicherte,
   unvollstaendig konsumierte Scanner-Dateien kontrolliert in die SMB-Inbox
   zuruecklegen.

Ein Rollback des Phase-1-Upgrades auf 2.20.6 folgt demselben Muster mit dem vor
Phase 1 erstellten Export, CNPG-Backup, den dazugehoerigen PVC-Snapshots und der
separaten Sicherung der Scanner-Inbox.

## Quellen

- [Paperless-ngx 2.20.15](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v2.20.15)
- [Offizieller v3-Migrationsleitfaden](https://github.com/paperless-ngx/paperless-ngx/blob/v3.0.4/docs/migration-v3.md)
- [Paperless-ngx 3.0.4](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v3.0.4)
- [Warnung zu 3.0.1](https://github.com/paperless-ngx/paperless-ngx/releases/tag/v3.0.1)
- [Paperless Backup und Export](https://github.com/paperless-ngx/paperless-ngx/blob/v3.0.4/docs/administration.md#backup)
- [Helm-Chart 0.24.1](https://github.com/gabe565/charts/blob/main/charts/paperless-ngx/Chart.yaml)
- [CNPG 1.25: Recovery Targets](https://cloudnative-pg.io/docs/1.25/recovery#recovery-targets)
