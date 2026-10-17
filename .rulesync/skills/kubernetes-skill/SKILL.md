---
name: kubernetes-skill
description: Review or change Kubernetes manifests in this Talos/ArgoCD GitOps repo for workload security, resources, exposure, RBAC, rollouts, and API drift. Use for infrastructure components, cross-cutting manifest changes, or a requested Kubernetes safety review; combine with add-app for new apps and renovate-bump for dependency updates.
targets: ["*"]
---

# Kubernetes failure-mode review (kubernetes-gitops)

Adapted from the local `kubernetes-skill` for this repo. Work on the Git source
of truth; ArgoCD applies it after CI and review. Read the relevant directory
`AGENTS.md` and the pertinent entries under `docs/learnings/` first.

## 1. Establish the target

- Identify the affected base and overlay, workload/controller, namespace, and
  production impact. Read the existing manifests and the nearest precedent.
- For a new app also load `add-app`; for a chart or image bump also load
  `renovate-bump`. Check upstream documentation for the actual API or chart
  version when behavior or fields are uncertain.
- Inspect the rendered output with `manifest-inspector` or
  `bash scripts/render.sh <dir>` inside `nix develop`. For charts, compare the
  render with the intended values; a values key alone proves nothing.

## 2. Check the relevant failure modes

Only investigate modes touched by the change, but include indirect effects
visible in the render:

| Mode | Check in this repository |
| --- | --- |
| Workload security | PodSecurity namespace labels; container security context; privileged, hostPath, hostNetwork, and mounted credentials. Explain any necessary exception. |
| Resources | Requests and limits, measured sizing, database CR resources and pinned images, HPA presence and target. Memory-based HPA is forbidden. |
| Exposure | Service type, Ingress host/TLS and `nginx.org/*` annotations, NetworkPolicy ingress/egress, selectors and ports. |
| Privilege | ServiceAccount, RBAC verbs/resources/scope, secret access, token automount. Grant only what the component uses. |
| Rollout and state | Probe behavior, update strategy, PDB, storage access mode, backup, migration and rollback implications. |
| API drift | Resource apiVersion/kind, CRD availability, operator version, deprecated fields, chart schema, and fields added by defaulting that may cause ArgoCD drift. |

Check `scripts/ci/known-gaps/` before interpreting an existing exception; it
does not authorize a new gap. Keep findings tied to source and rendered
resource names so the owner can fix the source file.

## 3. Validate without changing the live cluster

- Run `nix develop --command just validate` for a finished change. For a tight
  local loop use the relevant `just` recipe, then run the full gate.
- Do not use `kubectl apply`, `kubectl diff`, or server-side dry-run as a routine
  check. Even dry-run requires the corresponding write authorization; this
  project's agent credentials are read-only. Use local render/schema/CI checks.
- Use read-only cluster inspection only when live facts are needed and the
  credentials are available. Never mutate the cluster without explicit human
  write access for a named incident.

## Output

For a review, report only actionable findings as
`severity — source path:line → rendered resource — failure mode → fix`.
For an implementation, explain the chosen fix, verification result, and any
remaining deploy-time risk. If no issue is found, say which modes and rendered
resources were checked.
