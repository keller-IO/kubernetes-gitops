# ADR 0004 — Flurfunk: Kubernetes-Manifeste im eigenen GitLab-Repo statt in `apps/`

- **Status:** Umgesetzt
- **Datum:** 2026-09-18
- **Kontext:** Neue App `flurfunk` (Hausgemeinschafts-Tool, FastAPI + Vue,
  eigenes Quell-Repo auf `gitlab.jit-creatives.de/tommy/flurfunk`, nicht
  Teil der `keller.io`-Organisation)

## Ausgangslage

Alle bisherigen Apps liegen als Kustomize-Base+Overlay in
`apps/base/<app>` / `apps/overlays/main/<app>` in *diesem* Repo und werden
von der `appset-apps`-ApplicationSet automatisch als `app-<name>`
eingesammelt (ein `Application` pro `apps/overlays/main/*`-Verzeichnis).
Flurfunk ist die erste App, deren Quellcode nicht bei `keller-IO`/`jit`
liegt, sondern ein rein privates Projekt des Nutzers auf dessen eigenem
GitLab ist.

## Entscheidung

Statt Flurfunks Manifeste unter `apps/base/flurfunk` in diesem Repo zu
pflegen, leben sie im `k8s/`-Verzeichnis des Flurfunk-Quell-Repos selbst.
Dieses Repo bekommt nur eine einzelne, eigenständige `Application`
(`clusters/main/app-flurfunk.yaml`), die direkt auf
`https://gitlab.jit-creatives.de/tommy/flurfunk.git`, Pfad `k8s`, zeigt —
bewusst **nicht** über die `appset-apps`-Automatik, sondern als eigener
Eintrag in `root-app.yaml`s `directory.include` (siehe
[Learning dazu](../learnings/root-app-self-reference-not-auto-applied.md)
für die daraus folgende Bootstrap-Falle).

## Begründung

- Quellcode, Container-Image *und* Deployment-Definition liegen konsistent
  an einem Ort (`gitlab.jit-creatives.de`) — kein Umweg über ein
  GitHub-Repo, das inhaltlich nichts mit dieser privaten App zu tun hat.
- Dieses Repo (`kubernetes-gitops`, GitHub) enthält dadurch **keine**
  Flurfunk-spezifischen Details mehr — nur einen generischen Zeiger.
- SOPS/KSOPS funktioniert repo-unabhängig (der ArgoCD-repo-server bringt
  `ksops` + den age-Key selbst mit, siehe
  `infrastructure/base/argocd/secret-generator.yaml`) — Flurfunk hat dafür
  eine eigene, wortgleiche `.sops.yaml` mit denselben zwei age-Empfängern.
- ArgoCD braucht dafür ein eigenes Repository-Credential
  (`flurfunk-repo`-Secret in `infrastructure/base/argocd/secret.sops.yaml`,
  GitLab-Deploy-Token mit `read_repository`-Scope) — analog zum
  Terraform-verwalteten `keller-io-repo` fürs Bootstrap-Repo selbst, nur
  eben nachträglich per GitOps statt Terraform ergänzt.

## Trade-offs

- **Kein einheitlicher Überblick mehr** über alle App-Manifeste an einer
  Stelle — wer nach Flurfunk sucht, muss wissen, dass es woanders liegt.
  Gemildert durch diese ADR + die App-Zeiger-Datei selbst (kommentiert).
- **`appset-apps`s `ignoreDifferences`/Sync-Wave-Defaults gelten nicht**
  für eigenständige Applications — mussten in `app-flurfunk.yaml` einzeln
  gesetzt werden (`sync-wave: "5"`, `syncPolicy` dupliziert statt geerbt).
- Ein zusätzliches Repository-Credential und eine zusätzliche
  `.sops.yaml`/age-Konfiguration außerhalb dieses Repos zu pflegen (bei
  einer Empfänger-Rotation künftig **drei** Stellen statt zwei, siehe
  [Runbook SOPS-Empfänger](../runbooks/sops-recipients.md) — dort noch zu
  ergänzen).

## Konsequenz für künftige externe Apps

Dieses Muster (eigenständige `Application` + externes Repo statt
`apps/overlays/main/*`) ist jetzt der Präzedenzfall für jede weitere App,
deren Quellcode nicht in der `keller-IO`/`jit`-Organisation liegt. Checkliste:

1. `k8s/`-Kustomization im externen Repo (Namespace, Workload, Ingress,
   `secret-generator.yaml` + `secret.sops.yaml` mit denselben age-Empfängern
   wie hier).
2. `clusters/main/app-<name>.yaml` hier anlegen, `repoURL` aufs externe Repo.
3. `root-app.yaml`s `include`-Liste ergänzen **und danach manuell
   `kubectl apply -f clusters/main/root-app.yaml`** ausführen (wird sonst
   nicht automatisch übernommen).
4. Falls das externe Repo privat ist: Deploy-Token (`read_repository`) im
   externen Repo anlegen, `Secret` mit Label
   `argocd.argoproj.io/secret-type: repository` in
   `infrastructure/base/argocd/secret.sops.yaml` ergänzen.
5. Falls die App einen neuen öffentlichen Hostnamen bekommt: zuerst prüfen,
   ob HTTP-01 mit dem eigenen App-Ingress kollidiert (siehe
   [Learning zur DNS/TLS-Kette](../learnings/flurfunk-dns-and-http01-chain.md))
   — bei eigenem dauerhaftem Ingress für denselben Host lieber gleich DNS-01
   wählen, falls die Zone auf `dns01` liegt.
