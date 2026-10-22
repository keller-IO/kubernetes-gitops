# Runbooks

Operative Schritt-für-Schritt-Anleitungen (Restore, Rotationen, Incident-Response).
Pro Vorgang eine Markdown-Datei.

- [talos-autoupdate.md](talos-autoupdate.md) — Aktivierung, Drain-/Recovery-Gates und Abnahme automatischer Talos-Patches.
- [talos-live-audit-2026-10-18.md](talos-live-audit-2026-10-18.md) — verifizierte Nodes, N-1-Kapazitaet, Datenbanken, Backups und konkrete Freigabeschritte.
- [cluster-inspection-2026-10-20.md](cluster-inspection-2026-10-20.md) — Read-only-Bestandsaufnahme von Workloads, Speicher, CNPG/WAL, Alert-Historie und noch offenen Benachrichtigungs-/Bereinigungsschritten.
- [netbird-cluster-access.md](netbird-cluster-access.md) — Read-only-Clusterzugang ueber den jit-Tenant und Proxy-Policy-Diagnose.

- [inbetriebnahme.md](inbetriebnahme.md) — Go-Live-Checkliste (Blaupause → Produktion),
  über beide Repos, mit Shell-Commands und Datei-Hinweisen.
- [mailman-migration.md](mailman-migration.md) — Migration der Mailman-3-Suite von `192.168.2.15` nach Kubernetes.
- [cloud-dev-proxy-cutover.md](cloud-dev-proxy-cutover.md) — `cloud-dev.savar.de` vom direkten Traefik-Backend auf nginx-inc im Cluster umstellen.
- [paperless-v3-upgrade.md](paperless-v3-upgrade.md) — Zweistufiges Upgrade von Paperless-ngx 2.20.15 auf 3.x mit Preflight und Rollback-Gates.
- [mariadb-lts-upgrade.md](mariadb-lts-upgrade.md) — Stufenweises MariaDB-Server-Upgrade 11.4 → 11.8 → 12.3 mit Pre-Upgrade-Dumps und Rollback.
- [docker15-retirement.md](docker15-retirement.md) — Direkter WAN-Cutover auf nginx-inc `.246` und kontrollierte Abschaltung von `192.168.2.15`.
- [ciso-assistant-setup.md](ciso-assistant-setup.md) — CISO Assistant (VVT/GRC) auf `grc.jit.services`: Vor-Merge-Schritte, Keycloak-Client, Zugriffstest.
- [sops-recipients.md](sops-recipients.md) — age-Empfänger für die Secrets ergänzen oder entfernen (inkl. `sops updatekeys` über beide Repos).
- [mastodon-migration.md](mastodon-migration.md) — Migration von `jit.social` (mastodon02, `192.168.2.233`) nach Kubernetes.
- [mastodon-betrieb.md](mastodon-betrieb.md) — Repliken, PDBs und Drain-Prüfung für `jit.social`; Valkey als bekannter Single Point of Failure.

Weitere noch zu erstellen — siehe TODOs in
`docs/PRODUCTION-READINESS.md` (Abschnitt 11 Backup & DR).
