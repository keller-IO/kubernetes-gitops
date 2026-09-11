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
