# ADR 0001 — Identity-Provider: Authentik vs. Keycloak

- **Status:** Akzeptiert — Authentik bleibt
- **Datum:** 2026-06-15
- **Kontext:** Ressourcenoptimierter Homelab-Cluster (Talos), strikt GitOps via ArgoCD

## Kontext

Als OIDC-/SSO-Provider standen Authentik (aktueller Stand) und Keycloak zur Auswahl.
Es wurde geprüft, ob ein Wechsel auf Keycloak sinnvoll ist. Entscheidend sind hier zwei
Rahmenbedingungen: begrenzte Cluster-Ressourcen und ein durchgängig deklarativer
GitOps-Workflow (alle Konfiguration als YAML im Repo).

## Optionen

| Kriterium | Authentik | Keycloak |
|-----------|-----------|----------|
| Ressourcenbedarf | Leichtgewichtig | Schwergewichtig (JVM, mehr RAM/CPU) |
| Deklarative Config | **Blueprints** — native YAML, ideal für GitOps | Realm-Import via JSON / Operator / `keycloak-config-cli` — umständlicher |
| Protokoll-Abdeckung | OIDC, SAML, Forward-Auth | Sehr vollständig (OIDC/SAML), Föderation |
| Reife / Ökosystem | Jünger, kleinerer Maintainer-Kreis | De-facto-Standard, Red-Hat-Backing, große Community |
| Forward-Auth für Apps ohne OIDC | Ja, integriert | Nein (separater Proxy nötig) |

## Entscheidung

**Authentik bleibt.** Für diesen Cluster überwiegen:

1. **Ressourceneffizienz** — passt zum „resource-optimized"-Ziel; Keycloaks JVM-Footprint
   ist im Homelab spürbar.
2. **GitOps-Fit** — Authentik-Blueprints sind nativ deklarativ und liegen bereits als YAML
   im Repo (`infrastructure/base/authentik/blueprints/`: forgejo-, kimai-, paperless-oauth).
   Keycloak hätte keinen ebenso eleganten deklarativen Flow.
3. **Forward-Auth** — erlaubt Absicherung von Apps ohne eigenes OIDC ohne Zusatzkomponente.

## Konsequenzen

- Die bestehenden Blueprints und der Onboarding-Prozess (AGENTS.md → „OIDC / Authentik
  Blueprint Onboarding") bleiben unverändert gültig.
- Ein Wechsel auf Keycloak wäre erst erwägenswert, wenn SAML-lastige Enterprise-Apps,
  Identity-Föderation oder das größere Keycloak-Ökosystem benötigt werden. Dann müssten die
  Blueprints als Realm-Konfiguration neu aufgebaut werden.
