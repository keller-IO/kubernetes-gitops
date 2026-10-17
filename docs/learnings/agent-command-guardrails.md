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

## Runtime guard (agent tools)

`just guardrails` prueft nur das Repository — es kann einen Agenten nicht daran
hindern, einen mutierenden Befehl live auszufuehren. Diese zweite Schicht steht
seit der Rulesync-Migration genau einmal in `.rulesync/permissions.jsonc` und wird
von `just agents-setup` in native Tool-Berechtigungen generiert:

- Claude Code — `permissions.deny` in `.claude/settings.json` (`Bash(kubectl delete *)`)
- OpenCode — `permission.bash` in `opencode.jsonc`
- Codex — `prefix_rule(...)` in `.codex/rules/rulesync.rules`
- Cursor — `Shell(...)` in `.cursor/cli.json`

Die Muster sind bewusst der kleinste gemeinsame Nenner (`<tool> <verb> *`): Codex
matcht jedes Wort als literales Token und verwirft ein Glob innerhalb oder vor
einem Wort stillschweigend — alles reichere als ein abschliessender `*` schuetzt
die anderen Tools, aber **nicht** Codex. Globale Flags vor dem Verb
(`kubectl -n prod delete pod x`, `helm -n x upgrade`) lassen sich nicht als
Codex-Prefix ausdruecken und sind darum in keinem Tool abgedeckt — der read-only
Kubeconfig bleibt die eigentliche Kontrolle, diese Liste ist Defense in Depth.

## Prevention

`just guardrails` und CI pruefen:

- keine `:latest` Images und kein `imagePullPolicy: Always`
- keine offensichtlichen Klartext-Secrets ausserhalb `*.sops.yaml`
- keine mutierenden Cluster-Kommandos in `justfile`, `.github/`, `.forgejo/` oder
  `scripts/`
- keine Write-Verben und kein Secret-Zugriff im `kubernetes-mcp` RBAC
