# kubernetes-gitops — AGENTS.md

## Agent setup
On every fresh clone or worktree, run `nix develop --command just agents-setup`
before working in this repository. This generates local rules, skills, subagents,
permissions, and MCP configuration from `.rulesync/`. Start a new agent session
so the generated tools are discovered. The tracked root `AGENTS.md` and
`CLAUDE.md` are bootstrap copies of this rule; edit this source and regenerate.

## Project contract
- ArgoCD manages the Talos Kubernetes cluster from this repository. Change
  manifests through GitOps, not by editing live resources. Use Kustomize
  base/overlay layouts and `helmCharts:` inflation. There is no Flux.
- For a new app, load `add-app`; for a chart or image bump, load
  `renovate-bump`. Inspect **rendered** manifests for new or bumped charts,
  using `manifest-inspector` when useful. Values alone do not prove the result.
- New app database CRs use CNPG for Postgres or mariadb-operator for MariaDB.
  Set requests and limits in `spec.resources`, pin `spec.image`/`spec.imageName`,
  and size requests from measured usage. Existing exceptions in
  `scripts/ci/known-gaps/` do not authorize new gaps.
- No unallowlisted HPA or memory-based autoscaling. Never use floating image
  tags (`latest`) or `imagePullPolicy: Always`.
- Use `nginx.org/*` ingress annotations and hosts from `cluster-config.yaml`.
  App backups go daily to Ceph S3. Keep app secrets SOPS-encrypted.
- OIDC uses external Keycloak, realm `bgt` at
  `https://auth.savar.de/realms/bgt`. Ask the user before onboarding a client;
  enable OIDC only after the client, redirect URI, and SOPS secret match. Do
  not create new Authentik blueprints.

## Agent safety and workflow
- Start non-trivial changes from current `main` in a feature worktree. Run
  `nix develop --command just validate` before opening a PR; CI and review
  gate ArgoCD reconciliation.
- Live cluster inspection requires read-only credentials. Never run mutating
  `kubectl`/`talosctl` commands without explicit human write access for a
  named incident. `.rulesync/permissions.jsonc` adds tool-level denials;
  the read-only credentials remain the actual access boundary.
- Never commit kubeconfig, talosconfig, age private keys, API tokens, or
  plaintext SOPS contents.
- Read the relevant directory `AGENTS.md` and `docs/learnings/` before complex
  changes. After unexpected operational effects, use `write-learning` and add
  a CI guardrail for checkable patterns.
- Delegate mechanical searches, counts, and inventories to the read-only
  `sweeper` subagent. Start it on the cheapest suitable small model: Claude
  uses its pinned model; for OpenCode, Codex, and Cursor choose an available
  cheap model in the dispatch call or configure the client's default subagent
  model. A prompt alone cannot change a model the client already selected.
- For public routing or DNS changes, read the current runbook under
  `docs/runbooks/` and verify registry delegation before editing `dns01`.
  Copy operational documentation to
  `192.168.23.19:/root/ansible/kellerio-docs/`.

## Rulesync resources
- `.rulesync/` is the source for root rules, skills, subagents, MCP servers,
  and permissions. Regenerate after source changes with
  `nix develop --command just agents-setup`; `just agents-check` detects
  missing or stale tool files. Only root `AGENTS.md` and `CLAUDE.md` are
  tracked bootstrap outputs; other tool-native outputs are gitignored.
- `keller-kubernetes` uses the GitOps-managed read-only MCP server. Set
  `KELLER_KUBERNETES_MCP_AUTH` outside the repository to the complete
  `Basic <base64(mcp:password)>` header value before starting the agent.
- Available workflows: `add-app` for app onboarding, `renovate-bump` for
  dependencies, `write-learning` for incidents; `manifest-inspector` audits
  rendered resources, `validate-triage` maps CI failures to files, and
  `sweeper` returns compact `path:line` evidence for mechanical lookups.
