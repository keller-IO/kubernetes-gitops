# keller.io — Homelab GitOps

Deklaratives, GitOps-gesteuertes Kubernetes-Setup für einen Homelab-Cluster auf
**Talos Linux**, ausgerollt über **ArgoCD**. Der gesamte Cluster-Zustand ist in diesem
Repository beschrieben — Änderungen passieren ausschließlich über Git-Commits, nicht per
`kubectl edit`.

> **Hinweis — Blaupausen-Phase:** Alle Manifeste sind funktionsbereite Vorlagen mit
> Platzhaltern (`*.jit.platzhalter`, `CHANGE ME`, `REPLACE_ME`). Was bis zum
> Produktivbetrieb noch fehlt, steht in [`docs/PRODUCTION-READINESS.md`](docs/PRODUCTION-READINESS.md).

---

## Inhaltsverzeichnis

- [Wie es funktioniert](#wie-es-funktioniert)
- [Repository-Aufbau](#repository-aufbau)
- [Plattform-Komponenten](#plattform-komponenten)
- [Anwendungen](#anwendungen)
- [Entwicklungsumgebung (Nix Shell)](#entwicklungsumgebung-nix-shell)
- [Lokale Validierung](#lokale-validierung)
- [Secrets verwalten (SOPS + age)](#secrets-verwalten-sops--age)
- [Cluster-Bootstrap](#cluster-bootstrap)
- [Weiterführende Dokumentation](#weiterführende-dokumentation)

---

## Wie es funktioniert

Das Repo folgt dem **App-of-Apps-Pattern**: Eine ArgoCD-Root-Application zeigt auf
`clusters/main/` und erzeugt von dort aus zwei ApplicationSets — eines für die
Plattform-Infrastruktur, eines für die Anwendungen. Jede Komponente wird per **Kustomize**
gerendert (Helm-Charts werden über `helmCharts:` inflationiert), sodass ArgoCD am Ende reine
Kubernetes-Manifeste anwendet.

```
Git push ──▶ ArgoCD (root-app) ──▶ ApplicationSets ──▶ Kustomize/Helm ──▶ Cluster
```

---

## Repository-Aufbau

| Pfad | Inhalt |
|------|--------|
| `clusters/main/` | ArgoCD-Einstiegspunkte: `root-app.yaml`, `projects.yaml`, ApplicationSets für Infrastruktur und Apps |
| `infrastructure/base/` | Plattform-Services (CNI, Ingress, Operatoren, Authentik, Monitoring) als Kustomize-Bases mit Helm-Inflation |
| `infrastructure/overlays/main/` | Cluster-spezifische Patches der Infrastruktur |
| `apps/base/` | Anwendungs-Blaupausen (je App: Workload, Datenbank, Cache, Backup, Secret-Vorlage) |
| `apps/overlays/main/` | Cluster-spezifische Patches (Hostnamen etc.) — von der ApplicationSet automatisch ausgerollt |
| `docs/` | Production-Readiness-Checkliste, Runbooks und Learnings |
| `scripts/` | CI-Helfer und Migrationswerkzeuge |
| `justfile` | Task-Runner für die gängigen Workflows (`build`, `test`, `lint`, `secrets-check`) |
| `flake.nix` / `.envrc` | Reproduzierbare Entwicklungsumgebung (siehe unten) |
| `renovate.json` | Automatische Dependency-Updates (Helm-Charts, Container-Images) |
| `.sops.yaml` | Verschlüsselungsregeln für Secrets |
| `.forgejo/workflows/` | CI-Pipeline (Render-, Schema- und Secret-Checks) |

---

## Plattform-Komponenten

Diese Dienste bilden das Fundament des Clusters und liegen unter `infrastructure/base/`.

| Komponente | Aufgabe |
|------------|---------|
| **ArgoCD** | GitOps-Controller — gleicht den Cluster-Zustand kontinuierlich mit diesem Repo ab |
| **Cilium** | CNI / Netzwerk-Layer (eBPF-basiertes Pod-Networking & Policies) |
| **NGINX Ingress** | Ingress-Controller — externer HTTP(S)-Zugang zu den Anwendungen |
| **cert-manager** | Automatische TLS-Zertifikate (Let's Encrypt via DNS-01) |
| **Authentik** | Identity-Provider / OIDC — Single Sign-On, mit Blueprints pro App |
| **CloudNativePG (CNPG)** | PostgreSQL-Operator inkl. Backups (Barman → S3) |
| **mariadb-operator** | MySQL/MariaDB-Operator (z. B. für WordPress) |
| **Valkey** | Redis-kompatibler Cache — eine kleine, eigenständige Instanz pro App (`apps/base/*/cache.yaml`) |
| **VictoriaMetrics + Grafana** | Monitoring-Stack (Metriken, Dashboards, Alerting) |
| **Ceph (Storage)** | Persistenter Speicher: RBD (Block), CephFS (Datei), S3 (Objekt) |
| **SOPS + age** | Verschlüsselung von Secrets im Git-Repo (KSOPS im ArgoCD repo-server) |
| **Renovate** | Hält Helm-Chart- und Image-Versionen automatisch aktuell |

---

## Anwendungen

Die ausgerollten Workloads liegen unter `apps/base/` (Blaupause) und
`apps/overlays/main/` (Cluster-Variante).

| Anwendung | Beschreibung |
|-----------|--------------|
| **[Forgejo](https://forgejo.org/)** | Git-Hosting (diese Plattform) |
| **[Kimai](https://www.kimai.org/)** | Zeiterfassung |
| **[Mastodon](https://joinmastodon.org/)** | Föderiertes soziales Netzwerk |
| **[Paperless-ngx](https://docs.paperless-ngx.com/)** | Dokumenten-Management / Archiv |
| **[Roundcube](https://roundcube.net/)** | Webmail-Oberfläche (externer Mailserver) |
| **[WordPress](https://wordpress.org/)** (×3) | Drei separate WordPress-Instanzen |
| **[Collabora](https://www.collaboraonline.com/)** | Online-Office (Dokumentenbearbeitung) |
| **[Renovate](https://docs.renovatebot.com/)** | Self-hosted Dependency-Update-Bot (CronJob) |

---

## Entwicklungsumgebung (Nix Shell)

Alle benötigten Werkzeuge sind in `flake.nix` gepinnt — keine manuelle Installation nötig.

```bash
nix develop          # Dev-Shell mit allen Tools betreten
```

Mit [direnv](https://direnv.net/) lädt sich die Shell beim Betreten des Verzeichnisses
automatisch (eine `.envrc` mit `use flake` liegt bereits im Repo):

```bash
direnv allow         # einmalig erlauben
```

Enthaltene Werkzeuge: `just`, `kustomize`, `kubeconform`, `helm`, `sops`, `age`,
`yamllint`, `kubectl`.

---

## Lokale Validierung

Vor jedem Commit lassen sich alle Manifeste lokal prüfen — identisch zur CI:

```bash
just build          # rendert jede Overlay mit kustomize (Helm-Inflation)
just test           # rendert + validiert gegen Kubernetes-/CRD-Schemas
just lint           # YAML-Linting
just secrets-check  # stellt sicher, dass kein *.sops.yaml unverschlüsselt ist
```

`just` ohne Argument listet alle verfügbaren Recipes auf.

---

## Secrets verwalten (SOPS + age)

Secrets werden **verschlüsselt** im Repo abgelegt (`*.sops.yaml`). Nur `data`/`stringData`
werden chiffriert — Metadaten bleiben lesbar und diffbar.

```bash
age-keygen -o age.agekey                 # 1. age-Schlüssel erzeugen (privat, NICHT committen)
# 2. Public Key in .sops.yaml unter creation_rules eintragen
just encrypt apps/base/forgejo/secret.sops.yaml   # 3. Secret verschlüsseln
just decrypt apps/base/forgejo/secret.sops.yaml   #    bzw. zum Ansehen entschlüsseln
```

> Der private age-Key gehört **niemals** ins Git — er ist bereits in `.gitignore`
> ausgeschlossen. Im Cluster liegt er als `sops-age`-Secret für den ArgoCD repo-server.

---

## Cluster-Bootstrap (Kurzform)

1. Talos-Cluster aufsetzen, `kubeconfig` beziehen.
2. ArgoCD installieren.
3. age-Key als `sops-age`-Secret im `argocd`-Namespace anlegen.
4. Root-Application anwenden:
   ```bash
   kubectl apply -f clusters/main/root-app.yaml
   ```

Ab hier übernimmt ArgoCD und rollt Infrastruktur und Apps aus. Detaillierte Schritte:
[`docs/PRODUCTION-READINESS.md`](docs/PRODUCTION-READINESS.md).

---

## Weiterführende Dokumentation

- [`AGENTS.md`](AGENTS.md) — Architektur-Prinzipien & Arbeitsregeln
- [`docs/PRODUCTION-READINESS.md`](docs/PRODUCTION-READINESS.md) — Weg zur Produktion
- [`docs/runbooks/`](docs/runbooks/) — Betriebsabläufe
- [`docs/learnings/`](docs/learnings/) — gesammelte Erkenntnisse
- [`docs/decisions/`](docs/decisions/) — Architecture Decision Records
