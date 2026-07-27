# Agent Command Guardrails

## What went wrong

KI-Agenten mit Admin-Kubeconfig koennen GitOps umgehen. Ein einzelner falscher
`kubectl delete`, `kubectl apply` oder `talosctl apply-config` kann den Live-Cluster
veraendern, bevor CI, Review oder ArgoCD die Aenderung sehen.

## Why it failed

Prompt-Regeln allein sind kein Sicherheitsmodell. Sobald ein Agent Shell-Zugriff und
privilegierte Cluster-Credentials hat, kann er Repository-Regeln umgehen. CI sieht nur
Git-Diffs, nicht manuelle Live-Mutationen.

## The correct approach

- Agenten arbeiten standardmaessig ueber Branch, Git-Diff, `just validate` und PR.
- Live-Cluster-Zugriff fuer Agenten ist read-only.
- Schreibzugriff wird nur fuer einen benannten Incident und mit menschlicher
  Freigabe bereitgestellt.
- Kubernetes MCP bleibt read-only und darf keine Secrets lesen.
- Automationen duerfen keine mutierenden `kubectl`/`talosctl`-Befehle enthalten,
  ausser sie tragen eine explizite `guardrails: allow-live-mutation` Ausnahme mit
  dokumentiertem Scope.

## Prevention

`just guardrails` und CI pruefen:

- keine `:latest` Images und kein `imagePullPolicy: Always`
- keine offensichtlichen Klartext-Secrets ausserhalb `*.sops.yaml`
- keine mutierenden Cluster-Kommandos in `justfile`, `.github/`, `.forgejo/` oder
  `scripts/`
- keine Write-Verben und kein Secret-Zugriff im `kubernetes-mcp` RBAC
