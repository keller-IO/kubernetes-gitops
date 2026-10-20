# mariadb-operator: Major-Upgrades stufenweise statt Renovate-Sprung

Upgrade am 20.10.2026 von `0.38.1` auf `26.10.1` (#329, #330, #331).

## Symptom

Renovate öffnete #265 als einen einzigen Sprung `0.38.1 → 26.10.1`. Die CI
war grün, sagte aber nichts über den Bump aus: Der Integrations-Pilot deployt
nur ArgoCD, CNPG, Gatus und Goloom (`scripts/ci/integration/prepare.py`), keine
MariaDB. `validate` prüft nur die Schemas der CRs gegen die neuen CRDs.

## Mechanismus

- Die Upgrade-Guides für 25.08, 25.8.1 und 25.10 verbieten, Zwischenversionen
  zu überspringen: *"Do not attempt to skip intermediate version upgrades."*
  Erst ab 26.x heißt es „otherwise you may upgrade directly". Renovate kennt
  diese Regel nicht und schlägt immer den höchsten Tag vor.
- Laut Guide sollen die Webhook-Konfigurationen vor dem Upgrade gelöscht
  werden. Im Ablauf mit ArgoCD (`ServerSideApply=true`, `prune: true`) war das
  nicht nötig. Die `MutatingWebhookConfiguration` fällt mit 25.10 weg und wird
  von ArgoCD gepruned.
- Der Operator ändert in diesen Schritten das StatefulSet-Template einer
  standalone MariaDB nicht, die DB-Pods liefen ohne Neustart weiter. Galera und
  Replikation hätten zusätzliche Migrationen gebraucht (`syncBinlog`,
  `migrate_v25.10.0.sh`, Update der Data-Plane), die wir nicht nutzen.
- Ab 26.x heißen die logischen Dumps `backup.<ts>.sql.gz` statt
  `backup.<ts>.gzip.sql`. Retention und Restore erkennen beide Formate
  (`pkg/backup/processor.go`, „legacy format").

## Korrektur

Pfad `0.38.1 → 25.8.4 → 25.10.4 → 26.10.1`, ein PR pro Schritt. Vor jedem PR
gab es diese Prüfungen:

1. Eine Generalprobe auf Kind mit einer kimai-ähnlichen Standalone-MariaDB über
   den kompletten Pfad. Dabei wurden das StatefulSet-Template, die Pod-UID, die
   Daten, Backup-Jobs und die Admission geprüft.
2. Ein On-Demand-Dump nach Garage über
   `kubectl create job --from=cronjob/<name>-mariadb <name>-mariadb-pre-op-upgrade-<datum>`.
3. Nach jedem Sync wurden geprüft: ArgoCD-App `infra-mariadb-operator` Synced
   und Healthy, Pod-UIDs der MariaDBs unverändert, alle `MariaDB`-CRs Ready,
   Operator-Logs ohne Fehler.
4. Nach dem letzten Schritt lief ein Backup-Job nach dem Upgrade für alle fünf
   Instanzen.

## Prävention

- Renovate-PRs für mariadb-operator, die mehrere Minor- oder Major-Linien
  überspringen, nicht direkt mergen. Erst den Abschnitt „skip intermediate
  versions" in `docs/releases/UPGRADE_*.md` upstream prüfen.
- Eine MariaDB im Integrations-Pilot fehlt weiterhin (siehe
  `docs/PRODUCTION-READINESS.md`). Bis dahin ist die Generalprobe auf Kind der
  einzige Upgrade-Test für Operator-Bumps.
- Vor einem Major-Bump der Datenbank selbst (`11.4.5 → 12.x`) zusammen mit
  `spec.image` auch `updateStrategy.mariadbAutoUpgradeEnabled: true` setzen
  (Guide 26.10.1). Sonst startet MariaDB gegen ein Datadir, das nicht migriert
  wurde.
