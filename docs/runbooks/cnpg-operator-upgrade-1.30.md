# CNPG-Operator-Upgrade 1.25.0 → 1.30.0

Stand: 2026-09-11.

## Ausgangslage

- Live laeuft der Operator `ghcr.io/cloudnative-pg/cloudnative-pg:1.25.0`.
- In `main` steht seit dem 24.08.2026 der Chart `cloudnative-pg` 0.29.0 (= Operator 1.30.0,
  Renovate). Wegen des ArgoCD-Auto-Sync-Freeze wurde er nie ausgerollt; `infra-cnpg` steht
  deshalb OutOfSync (CRDs, Webhooks, RBAC, Deployment, Monitoring-ConfigMaps).
- Sechs Cluster, **alle mit `instances: 1`**: `crowdsec-pg`, `expense-pg`, `forgejo-pg`,
  `mailman-pg`, `paperless-pg`, `roundcube-pg`.

## Entscheidung: In-place-Update des Instance-Managers

Standard ist ein rollendes Update jedes Clusters mit abschliessendem Switchover. Bei einer
Instanz heisst das: jede Datenbank startet neu. Mit
`ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES: "true"` (Chart: `config.data`) tauscht der
Instance-Manager nur sein eigenes Binary und uebernimmt den laufenden Postmaster —
PostgreSQL laeuft weiter. Nebenwirkung: das Init-Container-Image in den Pods bleibt auf dem
alten Stand, die Pod-Definition zeigt die Operator-Version dann nicht mehr korrekt.

## Release Notes 1.26–1.30: relevant fuer uns

| Thema | Bewertung |
|---|---|
| In-tree `barmanObjectStore` (4 Cluster sichern so) | abgekuendigt, **Entfernung erst in 1.31.0** — 1.30 funktioniert, Migration auf das Barman-Cloud-Plugin vor 1.31 noetig |
| Metrics-Exporter nutzt Rolle `cnpg_metrics_exporter` statt Superuser (1.28.3) | betrifft nur eigene Queries auf Nutzertabellen; wir nutzen `cnpg-default-monitoring` |
| `.spec.monitoring.enablePodMonitor` abgekuendigt (1.26) | alle 6 Cluster nutzen es, funktioniert weiter |
| `cluster`-Referenz an ScheduledBackup/Database/Pooler unveraenderlich (1.29/1.30) | keine Auswirkung, wir aendern sie nicht |
| Primary-`Lease` fuer Promotion (1.30) | neu, bei einer Instanz ohne Auswirkung |
| Direkter Sprung ueber mehrere Minor-Versionen | laut Doku zulaessig (API v1 abwaertskompatibel, Empfehlung: neueste Version) |

## Vorbedingungen

- [ ] Frische Backups:
  - on-demand `Backup` `<cluster>-pre-cnpg130-20260911` fuer forgejo, mailman, paperless-ngx,
    roundcube → Phase `completed`
  - logische Dumps von `crowdsec-pg` und `expense-pg` (haben kein Barman-Backup), age-verschluesselt,
    auf cfgmgmt01 unter `/root/backups/cnpg-pre130-20260911/`
- [ ] Dieser PR gemergt (In-place-Schalter).
- [ ] PR #144 gemergt und `infra-monitoring` gesynct — sonst meldet `infra-cnpg` die konvertierten
  `VMPodScrape` weiter als extraneous; ohne #144 **ohne Prune** syncen.

## Ablauf

1. Stand festhalten: Pod-Namen, Startzeiten und Restart-Zaehler aller sechs Primaries,
   `kubectl get clusters.postgresql.cnpg.io -A`.
2. `infra-cnpg` hart refreshen und manuell syncen (Auto-Sync bleibt aus).
   CRDs sind gross; die Sync-Optionen des Infrastruktur-ApplicationSets muessen `ServerSideApply`
   abdecken, sonst scheitert das Apply am Annotations-Limit.
3. Beobachten:
   - Operator-Pod `Ready`, Image `1.30.0`, keine Fehler im Log.
   - Alle Cluster `Cluster in healthy state`.
   - **Primary-Pods nicht neu gestartet** (gleiche Startzeit, Restart-Zaehler unveraendert).
   - Condition `ContinuousArchiving` = `True` bei den vier Barman-Clustern.
4. Nach dem Upgrade je Barman-Cluster ein on-demand `Backup` → `completed`.
5. Anwendungen pruefen: `webmail.jit.services` (Login-Seite), `paperless.savar.de`,
   `git.jit.services`, `lists.jitmail.de`, `expense.porga.de`, CrowdSec-LAPI-Pod `Ready`.

## Rollback

Ein Operator-Downgrade nach dem CRD-Update ist nicht vorgesehen. Solange nur das
Operator-Deployment scheitert und die Cluster unberuehrt sind: Git-Revert und erneuter Sync.
Sind Datenbanken beschaedigt: Restore aus den Backups der Vorbedingungen (Barman-Recovery bzw.
`age -d | gunzip | psql` fuer die beiden logischen Dumps).

## Ergebnis 11.09.2026

Ausgefuehrt 18:50–18:55 UTC. `infra-cnpg` `Synced/Healthy`, Operator
`ghcr.io/cloudnative-pg/cloudnative-pg:1.30.0`, 0 Fehler im Operator-Log, alle sechs
Cluster `Cluster in healthy state`, Instance-Manager in jedem Pod `1.30.0`
(`/controller/manager version`). Die vier Barman-Cluster wurden anschliessend erneut
gesichert, alle vier `completed`.

### Korrektur: der In-place-Schalter hat den Neustart NICHT verhindert

Alle sechs Postgres-Pods wurden neu erzeugt (18:51–18:54, Init-Image jetzt `1.30.0`,
Restart-Zaehler auf 0). `ENABLE_INSTANCE_MANAGER_INPLACE_UPDATES` greift nur, wenn sich
**ausschliesslich** die Version des Instance-Managers unterscheidet. Zwischen 1.25 und 1.30
hat sich die Pod-Definition selbst geaendert (Init-Container-Image, Probes jetzt ueber TLS),
und solche Aenderungen erzwingen ein Neuerzeugen des Pods.

Fuer den naechsten Sprung heisst das: bei einem Minor-Upgrade mit geaenderter Pod-Definition
**immer ein Ausfallfenster einplanen**, bei Clustern mit `instances: 1` etwa eine Minute pro
Cluster. Der Schalter bleibt trotzdem sinnvoll fuer Patch-Upgrades.

### Was die Anwendungen gesehen haben

Zwischen 18:51:20 und 18:54:23 meldeten mailman-core, mailman-web, roundcube, paperless,
crowdsec-lapi und expense-tracker Verbindungsfehler der Form
`connection to server ... failed: Operation not permitted`. Das ist Ciliums Antwort, solange
ein Service keine bereiten Endpoints hat — kein NetworkPolicy-Problem. Seit 18:54 sind alle
Verbindungen wieder normal; Mailman-LMTP antwortet mx02 wieder, Queue leer.

### Statusfelder taugen nicht mehr zur Pruefung

`status.lastArchivedWAL`, `lastSuccessfulBackup` und verwandte Felder werden seit 1.26 nicht
mehr geschrieben (Umstieg auf die Plugin-Architektur) und standen nach dem Upgrade auf
`None`. Pruefen stattdessen ueber:

```sql
select archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_time
  from pg_stat_archiver;
```

und ueber den Zustand der `Backup`-Objekte.

### Befund: zwei Cluster ohne jede Sicherung

`crowdsec-pg` und `expense-pg` haben **kein `barmanObjectStore` und keinen ScheduledBackup**.
`archive_mode` steht zwar auf `on`, das `archive_command` des Instance-Managers laeuft aber
ohne Ziel ins Leere — in 24 Stunden keine einzige `wal-archive`-Logzeile, die Zaehler in
`pg_stat_archiver` sind daher irrefuehrend. Einziger Schutz sind derzeit die logischen Dumps
vom 11.09.2026 (age-verschluesselt auf cfgmgmt01 unter
`/root/backups/cnpg-pre130-20260911/`). **Offen: beide Cluster wie die anderen vier an
Garage anbinden.**

### Offene Beobachtung: WAL-Archivierung schlug am 12.09. kurz fehl

Zwischen 06:56 und 07:07 UTC scheiterte `barman-cloud-wal-archive` bei `roundcube-pg`
(6-mal) und `paperless-pg` (2-mal) mit `exit status 4`, jeweils nach rund fuenf Minuten
Laufzeit; die Wiederholung war erfolgreich, Stand 07:20 archivieren beide normal. Garage war
zu dieser Zeit gesund (`HEALTHY`, 5,8 TiB frei, keine Fehler im Log), der Verdacht liegt
daher auf dem IPsec-Pfad Halbe↔Potsdam. Zu beobachten: die naechtlichen ScheduledBackups um
02:00 und `failed_count` in `pg_stat_archiver`.

### Naechster Schritt

Migration der vier Barman-Cluster auf das Barman-Cloud-Plugin, bevor CNPG 1.31 die
eingebaute Variante entfernt.
