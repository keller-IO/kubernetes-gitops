# Runbooks

Operative Schritt-für-Schritt-Anleitungen (Restore, Rotationen, Incident-Response).
Pro Vorgang eine Markdown-Datei.

- [inbetriebnahme.md](inbetriebnahme.md) — Go-Live-Checkliste (Blaupause → Produktion),
  über beide Repos, mit Shell-Commands und Datei-Hinweisen.
- [mailman-migration.md](mailman-migration.md) — Migration der Mailman-3-Suite von `192.168.2.15` nach Kubernetes.
- [cloud-dev-proxy-cutover.md](cloud-dev-proxy-cutover.md) — `cloud-dev.savar.de` vom direkten Traefik-Backend auf nginx-inc im Cluster umstellen.
- [paperless-v3-upgrade.md](paperless-v3-upgrade.md) — Zweistufiges Upgrade von Paperless-ngx 2.20.15 auf 3.x mit Preflight und Rollback-Gates.
- [docker15-retirement.md](docker15-retirement.md) — Direkter WAN-Cutover auf nginx-inc `.246` und kontrollierte Abschaltung von `192.168.2.15`.

Weitere noch zu erstellen — siehe TODOs in
`docs/PRODUCTION-READINESS.md` (Abschnitt 11 Backup & DR).
