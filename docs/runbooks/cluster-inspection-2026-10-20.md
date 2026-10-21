# KellerIO-Clusterinspektion vom 20.10.2026

Read-only-Momentaufnahme vom 20.10.2026, etwa 17:47–17:50 UTC. Zugriff erfolgte
über die ausdrücklich freigegebene Kubernetes-API; Datenbankabfragen waren
ausschließlich `SELECT`. Es wurden keine Ressourcen geändert, keine Secrets
ausgelesen und keine Testbenachrichtigung gesendet. Die Ergebnisse beschreiben
den Prüfzeitraum und sind keine dauerhafte Kapazitäts- oder Verfügbarkeitsgarantie.

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 20.10.2026 |
| --- | --- | --- |
| ArgoCD und Workloads | Verwaltete Apps und Controller bereit | 45/45 Applications Synced und Healthy; 90 Deployments, StatefulSets und DaemonSets mit gewünschten Replicas bereit; 205 Pods, kein aktiver Pending-, Unknown-, unbereiter oder terminierender Pod |
| Persistenter Speicher | Bound Claims, nachvollziehbare Attachments und ausreichend Platz | 57 PVCs und 57 PVs Bound; alle PVs Ceph RBD CSI, keine lokalen/statischen PVs; 51 Attachments `attached=true`, sechs Claims derzeit ohne Attachment (siehe unten) |
| PostgreSQL | CNPG-Cluster und Replica-Slots gesund | 10 Cluster gesund, je zwei Instanzen bereit; alle zehn Replicas streamen, aktive Slots halten bei der Probe 0 WAL-Bytes zurück |
| Monitoring und Benachrichtigung | Gesunde Scrapes und nutzbarer Alert-Empfänger | Regeln und Targets aktuell gesund; zwei fachliche Monitoring-Alerts aktiv. Alertmanager verwirft Benachrichtigungen über den `null`-Empfänger |
| Jobs und CronJobs | Aktuelle Läufe erfolgreich, alte Fehler richtig eingeordnet | Aktuelle Datenbank-Backups erfolgreich; fünf alte Jobs lösen weiterhin `KubeJobFailed` aus |

## Workloads und Jobs

45 ArgoCD-Applications waren Synced und Healthy. Drei Applications meldeten
`ExcludedResourceWarning` für EndpointSlices oder Leases; die globalen ArgoCD-
Excludes sind konfiguriert und die Objekte standen nicht in den jeweiligen
Application-Ressourcen. 19 laufende und bereite Pods hatten Neustarts, alle
beobachteten letzten Terminierungen waren vom 19.10.; kein Pod war OOMKilled.

Vier Warn-Events betrafen Readiness-Probes. Kimais Probe folgte einem HTTP-
Redirect und hatte 10.165 `ProbeWarning`-Events seit dem 19.10.; Mastodon und
WordPress 1/2 hatten einzelne Readiness-Fehler. Alle betroffenen Pods waren
zum Prüfzeitpunkt Running und Ready. Der Kimai-Fix auf `/en/login` wurde im
Arbeitsstand vorbereitet; der Pfad und die Login-Seite lieferten HTTP 200.
Gatus public meldete beim letzten Abruf 21/21 erfolgreiche Endpunkte; die
19 HTTP-Ergebnisse stammten von etwa 17:51 UTC, die zwei extern gemeldeten Paperless-
Ergebnisse von etwa 17:45 UTC.

Es gab 13 CronJobs; Renovate ist laut Git-Kommentar seit 28.07. absichtlich
suspendiert. Fünf erhaltene Jobs waren fehlgeschlagen und erzeugten aktive
`KubeJobFailed`-Alerts:

| Namespace | Job | Einordnung |
| --- | --- | --- |
| mailman | `mailman-web-index-merge-persistent-20260801` | Einmaliger alter Fehler; Ursache aus dem Live-API nicht mehr feststellbar, kein späterer gleichnamiger Erfolg beobachtet |
| renovate | `renovate-29752140` | Historischer Fehler vor der dokumentierten Suspendierung |
| wordpress-1/2/3 | je `wordpress-mariadb-29809560` | Alte Fehler vom 05.09.; die aktuellen Läufe vom 20.10. waren erfolgreich |

Keine dieser Job-Historien beweist einen aktuellen Ausfall. Die fünf Jobs waren
zum Prüfzeitpunkt noch vorhanden; ihr Zustand nach der autorisierten Bereinigung
steht im Nachtrag. Mailmans Index-Job blieb bewusst erhalten, weil sein Fehler
weiter untersucht werden muss.

## Speicher

Alle 57 Claims waren Bound. Es gab keine lokalen oder statischen PVs und damit
keine gemeinsam genutzten lokalen Dateisysteme, deren Kapazität als PV-Quota
missverstanden werden könnte. Die sechs derzeit nicht angehängten Claims hatten
keinen laufenden Pod-Consumer; bei Kite gab es nur beendete Pods. Das ist eine
Bestandsaufnahme und keine Löschfreigabe.

| Namespace / PVC | Kapazität | Grund der fehlenden Attachment-Erfassung |
| --- | ---: | --- |
| mailman / `mailman-web-index-staging` | 100 Gi | Kein laufender Pod-Consumer |
| forgejo / `gitea-shared-storage` | 20 Gi | Kein laufender Pod-Consumer |
| wordpress-3 / `data-wordpress-mariadb-0` | 8 Gi | Kein laufender Pod-Consumer |
| wordpress-3 / `wordpress` | 5 Gi | Kein laufender Pod-Consumer |
| kite / `kite-storage` | 1 Gi | Nur beendete Pod-Consumer |
| authentik / `data-authentik-valkey-0` | 1 Gi | Kein laufender Pod-Consumer |

Container-seitiges `df` und `du -sx` wurden für 50 der 51 angehängten PVC-Pfade
verglichen. Beim Goloom-App-Container fehlte eine Shell; dort war kein sicherer
Verzeichnisvergleich möglich, daher gelten die Kubelet-Metriken. Der einzige
gemessene SubPath-Claim mit mehreren Verzeichnissen (Kimai) wurde für `data` und
`plugins` zusammengezählt: 860 KiB `du` gegenüber 884 KiB `df`. Die übrigen
Abweichungen lagen höchstens bei 24 KiB. Der Vergleich ist nur eine
Momentaufnahme; Container-`du` erfasst keine gelöschten, noch geöffneten Dateien.

| PVC | Nutzung / frei | Beobachtung |
| --- | ---: | --- |
| mailman / `mailman-web-data` (20 Gi) | 10.970.784 KiB `du`; 46 % frei | Größter beobachteter Verbrauch |
| monitoring / VictoriaMetrics (20 Gi) | 10.116.144 KiB `du`; 50 % frei | Zweitgrößter Verbrauch |
| mastodon / `mastodon-pg-1` und `mastodon-pg-2` (je 64 Gi) | 23.326.040 / 23.375.352 KiB `du`; je 64 % frei | Beide Datenbank-Replikas belegt |
| Goloom-App-PVC (5 Gi) | Kubelet-Metrik statt `du` | Image enthält keine Shell |

Die vom VictoriaMetrics-Kubelet gelieferten freien Prozentwerte stimmten nach
Rundung mit `df` überein. Die Inode-Metriken zeigten 4 % bei Matomo-Daten, 2 %
bei WordPress 1 und 1 % bei CISO PostgreSQL; viele Claims exportierten keine
Inode-Serie, daher ist das keine vollständige Inode-Abnahme.

## CNPG und WAL-Replikation

Alle zehn Cluster hatten zwei bereite Instanzen und den Status `healthy`. Je
Primary existierte genau ein aktiver physischer Slot für seine Streaming-Replica.
`wal_status` war `reserved`; `safe_wal_size` war `NULL`, weil
`max_slot_wal_keep_size=-1` (unbegrenzt) konfiguriert war. Die gemessene
zurückgehaltene WAL-Menge war bei allen Slots 0 Byte. Replicas standen auf
`streaming`/`async`, die LSNs waren aktuell. Alte Werte von
`pg_last_xact_replay_timestamp()` auf ruhigen Datenbanken waren kein Lag-Nachweis.

| Namespace / Cluster | Primary | Replica | Slot auf Primary |
| --- | --- | --- | --- |
| ciso-assistant / `ciso-assistant-pg` | `ciso-assistant-pg-2` | `ciso-assistant-pg-1` | `_cnpg_ciso_assistant_pg_1` |
| crowdsec / `crowdsec-pg` | `crowdsec-pg-2` | `crowdsec-pg-1` | `_cnpg_crowdsec_pg_1` |
| expense-tracker / `expense-pg` | `expense-pg-2` | `expense-pg-1` | `_cnpg_expense_pg_1` |
| forgejo / `forgejo-pg` | `forgejo-pg-2` | `forgejo-pg-1` | `_cnpg_forgejo_pg_1` |
| goloom / `goloom-pg` | `goloom-pg-2` | `goloom-pg-1` | `_cnpg_goloom_pg_1` |
| mailman / `mailman-pg` | `mailman-pg-2` | `mailman-pg-1` | `_cnpg_mailman_pg_1` |
| mastodon / `mastodon-pg` | `mastodon-pg-2` | `mastodon-pg-1` | `_cnpg_mastodon_pg_1` |
| monitoring-db / `monitoring-pg` | `monitoring-pg-1` | `monitoring-pg-2` | `_cnpg_monitoring_pg_2` |
| paperless-ngx / `paperless-pg` | `paperless-pg-2` | `paperless-pg-1` | `_cnpg_paperless_pg_1` |
| roundcube / `roundcube-pg` | `roundcube-pg-2` | `roundcube-pg-1` | `_cnpg_roundcube_pg_1` |

Der Slot-Status wurde pro Primary mit einer SELECT-Abfrage gelesen. Es wurden
keine inaktiven oder verwaisten Slots beobachtet. Neun tägliche Backup-CRs waren
am 20.10. erfolgreich; Mastodon läuft wöchentlich und sein letzter Prüf-Backup
war am 18.10. abgeschlossen. CNPG meldete für alle Cluster erfolgreiche letzte
Backups.

## Monitoring, Alerts und Benachrichtigung

Die Historie wurde später erneut für 19.10. 04:04 bis 21.10. 04:04 UTC mit
60-Sekunden-Abtastung abgefragt. Das ist eine Stichprobenreihe, kein dauerhaftes
Incident-Log; die Zeitpunkte unten sind jeweils letzte Samples und keine exakten
Übergangszeiten. Die Abfrage zählt Label-Serien, nicht Alert-Episoden. Die
folgenden Alerts hatten mindestens ein **firing**-Sample; pending-only Alerts
sind nicht aufgeführt.

| Alert | Letztes firing-Sample (UTC) | Status 21.10. 04:04 UTC |
| --- | --- | --- |
| `AlertingRulesError` | 19.10. 12:34 | Resolved |
| `InfoInhibitor` | 21.10. 04:04 | Firing (Helper) |
| `KubeControllerManagerInstanceUnreachable` | 19.10. 17:57 | Resolved |
| `KubeJobFailed` | 21.10. 04:04 | Firing (nur Mailman-Index-Job) |
| `KubePodNotReady` | 19.10. 12:47 | Resolved |
| `KubeSchedulerInstanceUnreachable` | 19.10. 17:57 | Resolved |
| `NodeDiskIOSaturation` | 19.10. 20:04 | Resolved |
| `NodeSystemSaturation` | 19.10. 11:48 | Resolved |
| `RecordingRulesError` | 19.10. 12:34 | Resolved |
| `RecordingRulesNoData` | 21.10. 04:04 | Firing |
| `RemoteWriteDroppingData` | 19.10. 12:26 | Resolved |
| `RequestErrorsToAPI` | 19.10. 11:52 | Resolved |
| `ScrapePoolHasNoTargets` | 20.10. 17:54 | Resolved |
| `ServiceDown` | 19.10. 11:39 | Resolved |
| `TargetDown` | 19.10. 17:57 | Resolved |
| `TooHighQueryLoad` | 19.10. 12:00 | Resolved |
| `TooManyErrorLogs` | 19.10. 11:02 | Resolved |
| `TooManyLogs` | 20.10. 23:48 | Pending at 21.10. 04:04 |
| `TooManyMissedIterations` | 19.10. 11:52 | Resolved |
| `TooManyScrapeErrors` | 19.10. 18:02 | Resolved |
| `UncleanShutdown` | 19.10. 12:30 | Resolved |

`Watchdog` war ebenfalls aktuell firing und ist erwartetes Heartbeat-Verhalten;
die Historientabelle oben fasst die abgefragten Regelgruppen zusammen. Viele
weitere Serien waren nur pending und sind daher keine firing-Alerts.
`RemoteWriteDroppingData` war ein echter Datenverlust: Die erhaltenen Zähler
belegen mindestens 1.857 verworfene vmalert-Remote-Write-Zeilen am 19.10. über
zwei Pods. Die betroffenen Regelserien und genauen Lücken sind nicht mehr
bestimmbar. Am 21.10. 04:07 UTC blieb der aktuelle Zähler bei 10 und hatte
über fünf Minuten keinen Zuwachs; das stellt die alten Daten nicht wieder her.
`TooManyLogs` war im Refresh pending: 215 Warnungen in sechs Stunden betrafen
überwiegend Abfragen mit mehr als fünf Sekunden Laufzeit. In den letzten fünf
Minuten gab es acht solcher Warnungen, keine Error-/Fatal-/Panic-Meldungen.
Die Regel reagiert bereits auf jede Warnung über 15 Minuten. Die langsamen
Abfragen bleiben ein Beobachtungspunkt; die Schwelle wurde nicht abgeschwächt.
Zum letzten Regelcheck meldeten alle 35 VMAlert-Gruppen `health=ok` und leeres
`lastError`; VMagent zeigte kein aktives nicht-erfolgreiches Target.

Monitoring-Befunde:

- `ScrapePoolHasNoTargets` zeigte auf einen verwaisten VMPodScrape für das
  nicht aktive Authentik-PostgreSQL. Das Objekt hatte keine Owner-Referenz und
  kein Argo-Tracking; die Authentik-Infrastructure-Application ist nicht aktiv.
  Der CR wurde im Follow-up am 20.10. nach Prüfung des fehlenden CNPG-Clusters,
  der fehlenden Pods/PodMonitors und seiner fehlenden Owner-Referenz gelöscht.
  `ScrapePoolHasNoTargets` war im Refresh 21.10. 04:04 UTC resolved.
- `RecordingRulesNoData` betraf `count:up0`. Wenn alle Targets gesund sind,
  liefert `count(up == 0)` einen leeren Vektor. Die Git-Konfiguration verwendet
  `sum(up == bool 0) without(instance,pod,node)`, das bei vorhandenen, gesunden
  Targets Null liefert und bei komplett fehlenden Targets keine Serie erzeugt.

Vor Rollout verwendete Alertmanager den `null`-Root-Empfänger; die damaligen
Zähler zeigten null Benachrichtigungen und null Zustellfehler. Die Git-Konfiguration
konfiguriert Email an `jit-list@jitmail.de` über `192.168.2.209:25`, mit
`require_tls: true` und TLS-Servername `mx02.jitcreatives.de`; Watchdog und
`InfoInhibitor` bleiben auf `null`. `amtool check-config` für die gerenderte
Konfiguration war erfolgreich. Ein SMTP-Probe aus dem Alertmanager-Pod erhielt
Banner und EHLO-Antwort; STARTTLS wurde angeboten. Der separate Host-TLS-Test
bestätigte TLS 1.3 und das Zertifikat für `mx02.jitcreatives.de`. Es wurde kein
`MAIL`/`DATA` gesendet. Diese Abnahme vor dem Merge ersetzt keinen
Zustellnachweis. Die Live-Abnahme nach Merge wird im zugehörigen PR festgehalten.

## Follow-up am 20./21.10.2026

Am 20.10. gegen 17:54 UTC wurden nach separater Freigabe vier historische Jobs
gelöscht: Renovate sowie die fehlgeschlagenen WordPress-MariaDB-Jobs in
WordPress 1/2/3. **Der Mailman-Index-Job blieb auf ausdrücklichen Wunsch
erhalten** und ist der noch zu untersuchende `KubeJobFailed`-Fall. Der verwaiste
Authentik-VMPodScrape wurde nach Prüfung ebenfalls entfernt. Der Refresh vom
21.10. 04:04 UTC bestätigte, dass nur der Mailman-Job noch `KubeJobFailed`
auslöste und `ScrapePoolHasNoTargets` resolved war.

Beim späteren Read-only-Follow-up am 21.10. gegen 04:07 UTC waren alle acht Nodes
Ready und ohne Pressure; Cilium meldete auf allen acht Nodes `OK` und die
API-`/readyz`-Prüfung bestand alle Checks. Das bestätigt nur diese Folgeprobe,
nicht rückwirkend den Prüfstand vom 20.10.

## Abnahme nach Merge und verbleibende Punkte

- Nach ArgoCD-Reconciliation Live-Konfiguration und `count:up0` prüfen,
  die Auflösung von `RecordingRulesNoData` sowie die Zustellung eines echten
  Alerts an die freigegebene JIT-Liste belegen.
- Ursache des erhaltenen Mailman-Index-Jobfehlers untersuchen;
  der Job wurde nicht gelöscht.
- Nach dem Kimai-Rollout Readiness und neue ProbeWarning-Events prüfen.
- **Nicht freigegeben:** Die sechs nicht angehängten PVCs löschen oder
  umwidmen. Eine Attachment-Lücke allein belegt keine Verwaisung.

