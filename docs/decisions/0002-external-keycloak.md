# ADR 0002 — External Keycloak as Identity Provider

- **Status:** Akzeptiert
- **Datum:** 2026-07-14

## Kontext

Der Cluster sollte ursprünglich Authentik selbst betreiben und App-OIDC per Authentik-Blueprints verwalten. Inzwischen existiert aber bereits ein produktiver Keycloak auf `auth01` für die Domain `auth.savar.de`.

Der relevante Realm ist `bgt` mit Issuer:

```text
https://auth.savar.de/realms/bgt
```

Keycloak läuft extern zum Kubernetes-Cluster. Dadurch entfällt der zusätzliche Authentik-Betrieb im ressourcenoptimierten Talos-Cluster.

## Entscheidung

Der Cluster nutzt den bestehenden externen Keycloak als OIDC-Provider. Authentik wird nicht als neue zentrale Identity-Komponente für diesen Cluster eingeführt.

## Konsequenzen

- App-Konfigurationen verwenden den Issuer `https://auth.savar.de/realms/bgt`.
- OAuth-Clients und Client-Secrets werden in Keycloak gepflegt und als SOPS-Secrets in den App-Manifests referenziert.
- Bestehende Authentik-Manifeste bleiben bis zur vollständigen Migration im Repo, werden aber nicht als Zielarchitektur weiterentwickelt.
- Apps ohne native OIDC-Unterstützung brauchen einen separaten Schutzmechanismus, weil Keycloak kein eingebautes Forward-Auth wie Authentik bereitstellt.

## Migrationsstand

- Keycloak Host: `auth01` (`192.168.2.30`).
- Laufender Container: `quay.io/keycloak/keycloak:26.5`.
- Öffentliches Discovery-Dokument für `https://auth.savar.de/realms/bgt` ist erreichbar.
- On-host Backups wurden vor dem Upgrade-Preflight erstellt:
  - `/opt/auth.savar.de/backups/keycloak-db-20260714T080035Z.sql.gz`
  - `/opt/auth.savar.de/backups/keycloak-files-20260714T080035Z.tar.gz`
- Custom SPI wurde in einer temporären Build-Umgebung erfolgreich gegen Keycloak `26.7.0` gebaut.

## Offene Schritte

- Keycloak nach Freigabe von `26.5.x` auf `26.7.0` aktualisieren.
- Custom SPI mit der Zielversion bauen und das Provider-JAR kontrolliert austauschen.
- Binärgewitter-Theme unter Keycloak einrichten und Realm `bgt` darauf umstellen.
- Fehlende Clients für `gatus`, `kite`, `forgejo` und `kimai` in Keycloak anlegen oder bestätigen.
- SOPS-Secrets der Apps mit den Keycloak Client-Secrets aktualisieren.
- App-OIDC erst nach Client- und Secret-Abgleich aktivieren.
