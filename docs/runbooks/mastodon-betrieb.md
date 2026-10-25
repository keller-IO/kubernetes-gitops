# Mastodon: Betrieb, Node-Ausfall und Drains

Stand 21.10.2026 (#339). Gilt für `jit.social` im Namespace `mastodon` nach dem
Cutover vom 19.10.2026. Die Migration selbst steht in
[mastodon-migration.md](mastodon-migration.md).

## Topologie

| Komponente | Repliken | Streuung | PDB | Bei Ausfall eines Nodes |
|---|---|---|---|---|
| Web (Puma) | 2 | hart, je Node | `mastodon-web`, `minAvailable: 1` | Die zweite Replik bedient weiter; Sessions liegen in der DB. |
| Streaming | 2 | hart, je Node | `mastodon-streaming`, `minAvailable: 1` | Clients verlieren die WebSocket-Verbindung und verbinden sich selbst neu. |
| Sidekiq `default` | 2 × 15 Threads | hart, je Node | `mastodon-sidekiq-default`, `minAvailable: 1` | Halber Durchsatz, bis die Replik neu läuft. Laufende Jobs gehen per Retry zurück in die Queue. |
| Sidekiq `scheduler` | genau 1 | — | keine | Geplante Jobs (`Scheduler::*`) verzögern sich bis zum Neustart. |
| PostgreSQL (CNPG) | 2 | hart, je Node | CNPG-eigene PDB | Switchover bzw. Failover auf den Standby. |
| Valkey | 1 (StatefulSet, ceph-rbd RWO) | — | keine | **Single Point of Failure**, siehe unten. |
| Elasticsearch | 1 | — | keine | Noch nicht angebunden; Mastodon nutzt die einfache Suche. |

Queues: `default` bearbeitet `default,8 push,6 ingress,4 mailers,2 pull fasp`.
Nur der Scheduler hört auf `scheduler` und reiht damit auch die Cron-Jobs aus
`config/sidekiq.yml` ein (`listened_queues_only`). Der Chart bricht ab, sobald
ein Worker mit `scheduler` mehr als eine Replik bekommt. Der Scheduler läuft mit
`Recreate`, damit beim Rollout nie zwei Prozesse gleichzeitig laufen. Die
übrigen Sidekiq-Worker nutzen `RollingUpdate` (`maxSurge: 1`,
`maxUnavailable: 0`).

Die Streuung ist `requiredDuringScheduling` auf `kubernetes.io/hostname`. Bei
fünf Workern bleiben im Rollout (eine Surge-Replik) und mit einem gedrainten
Node genug freie Nodes. Fallen drei Worker gleichzeitig aus, bleibt eine Replik
`Pending`; das ist so gewollt.

Die PDBs stehen auf `unhealthyPodEvictionPolicy: AlwaysAllow`. Eine Replik,
die nicht Ready ist, blockiert so keinen Drain. Sidekiq ist erst Ready, wenn
die Datei
`/opt/mastodon/tmp/sidekiq_process_has_started_and_will_begin_processing_jobs`
existiert.

Hinweis: Die `pdb`-Values des offiziellen Charts (1.2.5) haben kein Template.
Die PDBs liegen deshalb in `apps/base/mastodon/pdb.yaml`.

## Valkey: bekannter Single Point of Failure

Bewusst nicht redundant (Entscheidung in #339, siehe auch #286 und #295).
Mastodon unterstützt seit 4.3 Redis Sentinel (`REDIS_SENTINELS`,
`REDIS_SENTINEL_MASTER`). Das bräuchte drei Valkey-Pods und Sentinel ohne
Operator im Repo. Dem steht bei einem Node-Ausfall ein Mastodon-Ausfall
gegenüber: einige Minuten, wenn der Node zurückkommt, sonst bis zum
manuellen Eingriff unten.

Solange Valkey fehlt, schlagen fast alle Web-Anfragen fehl, weil Cache,
Rack::Attack und Sidekiq an Redis hängen. Streaming verliert Pub/Sub.
Sidekiq-Jobs bleiben in der Queue (AOF, `appendonly yes`).

- **Node kommt zurück** (Reboot, kurzer Netzausfall): Der Kubelet räumt den
  alten Pod ab, der StatefulSet startet `mastodon-valkey-0` neu. Das heilt
  sich ohne Eingriff, sobald der Node wieder `Ready` ist.
- **Node bleibt weg** (VM hängt, Host defekt): Das heilt sich **nicht** von
  selbst. Nach etwa 5 min (Toleration `unreachable`) markiert Kubernetes den
  Pod zum Löschen, er bleibt aber `Terminating`, weil kein Kubelet das
  bestätigt. Ein StatefulSet legt `mastodon-valkey-0` erst neu an, wenn der
  alte Pod wirklich weg ist. Das schützt das RWO-Volume vor zwei Schreibern.
  Web, Streaming und Sidekiq sind Deployments und starten dagegen sofort
  anderswo neu.
- **Geplanter Drain:** Die Eviction ist graceful, das Volume löst sich in
  Sekunden. Erwartet wird eine Lücke von etwa einer Minute (Detach, Attach,
  AOF laden). Wer das bewusst steuern will, verschiebt Valkey vor dem
  Wartungsfenster: Zielnode cordonen, dann `mastodon-valkey-0` löschen. Das
  braucht Schreibzugriff und gehört in ein benanntes Wartungsfenster, nicht in
  den Agenten-Alltag.

### Recovery bei dauerhaft ausgefallenem Node

Braucht Schreibzugriff für einen benannten Incident (siehe AGENTS.md).

1. **Fencing zuerst:** In Proxmox prüfen, dass die VM des Nodes wirklich
   **aus** ist, notfalls hart stoppen. Ein Node, der nur nicht erreichbar ist,
   aber noch läuft, kann weiter auf das RBD-Volume schreiben. Ohne diesen
   Nachweis nicht weitermachen.
2. Node als außer Betrieb markieren. Kubernetes löscht dann die Pods des
   Nodes und hängt die Volumes sofort ab, ohne auf den 6-min-Force-Detach zu
   warten:

   ```bash
   kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
   ```

3. Warten, bis `mastodon-valkey-0` auf einem anderen Node `Running` und
   `Ready` ist. Hängt das Mapping mit `rbd image ... is still being used`,
   ist der Watcher des alten Clients noch aktiv: `rbd status` auf dem Image
   prüfen und nach dem Fencing den Timeout abwarten.
4. Erst wenn der Node repariert und wieder gestartet ist, den Taint
   entfernen:

   ```bash
   kubectl taint nodes <node> node.kubernetes.io/out-of-service=nodeshutdown:NoExecute-
   ```

`kubectl delete pod --force --grace-period=0` ist nur die schlechtere
Variante. Sie löscht den Pod, das Volume bleibt aber bis zum Force-Detach
angehängt. Ohne Fencing ist auch sie unsicher.

## Drain-Prüfung

Vor einem Drain (Talos-Upgrade, Wartung) per Read-only-Zugang prüfen:

```bash
kubectl -n mastodon get pdb
# ALLOWED DISRUPTIONS muss für web, streaming und sidekiq-default 1 sein
kubectl -n mastodon get pods -o wide -l app.kubernetes.io/name=mastodon
# die beiden Repliken je Komponente liegen auf verschiedenen Nodes
```

`ALLOWED DISRUPTIONS: 0` heißt: eine Replik ist gerade nicht Ready. Erst
klären, warum, und nicht die PDB umgehen.

## Ressourcen (gemessen 21.10.2026)

| Komponente | Request | Limit | Gemessen |
|---|---|---|---|
| Web | 200m / 1Gi | 2Gi | ~1,05 GiB Mittel, 1,1 GiB Spitze; CPU 40m Mittel, 170m Spitze |
| Streaming | 50m / 128Mi | 512Mi | ~90 MiB Mittel, 115 MiB Spitze; CPU < 10m |
| Sidekiq `default` | 100m / 1Gi | 4Gi | bei `-c 25`: ~0,85 GiB Mittel, 1,8 GiB Spitze mit Rückstau (ffmpeg) |
| Sidekiq `scheduler` | 50m / 512Mi | 1536Mi | noch nicht getrennt gemessen |

Der Request für Web lag vor #339 mit 512Mi unter dem echten Bedarf. Insgesamt
steigen die Memory-Requests von 2,25 auf rund 4,75 GiB. Der tatsächliche
Mehrverbrauch liegt bei etwa 2 GiB. Nach einer Woche Betrieb die Sidekiq-Werte
aus der Messung nachziehen.

Datenbankverbindungen: Web 2 × 10 (2 Puma-Worker × 5 Threads), Sidekiq
2 × 15 + 5, dazu Streaming und Jobs. Vor #339 lag die Spitze bei 57 Backends,
`max_connections` steht auf dem Default 100. Wer Threads oder Repliken erhöht,
muss das gegenrechnen.

## Anmeldungen

Die Registrierung ist seit 25.10.2026 geschlossen (`registrations_mode = none`),
neue Konten nur per Einladung von Rollen mit der Berechtigung `invite_users`. Vorher meldeten sich trotz
Freigabepflicht Bots an, um Bestätigungsmails an fremde Adressen zu verschicken
([Learning](../learnings/mastodon-anmeldespam-mailversand.md)). Wieder öffnen:
`kubectl -n mastodon exec deploy/mastodon-web -c mastodon-web -- bin/tootctl settings registrations approved`.
`UserCleanupScheduler` löscht unbestätigte Konten nach 7 Tagen. Die Zahl
lokaler Accounts schwankt deshalb täglich. Lage prüfen:

```bash
primary=$(kubectl -n mastodon get cluster mastodon-pg -o jsonpath='{.status.currentPrimary}')
kubectl -n mastodon exec "$primary" -c postgres -- psql -XA -d mastodon_production -c \
  "select confirmation_sent_at::date, count(*) from users where confirmed_at is null and confirmation_sent_at is not null group by 1 order by 1 desc limit 10"
```

## Kein HPA

Die Replikenzahl ist fest (Projektregel: kein HPA ohne Allowlist, kein
Autoscaling nach Memory). Mehr Durchsatz in Sidekiq bringt bei der
fsync-gebundenen Datenbank ohnehin wenig, siehe
[mastodon-remote-cache-nach-cutover.md](../learnings/mastodon-remote-cache-nach-cutover.md).
