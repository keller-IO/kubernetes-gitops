---
name: renovate-bump
description: Handle Renovate PRs or manual dependency bumps in this repo — chart and image version bumps, rendered-manifest inspection, HPA/image/resource contracts, allowlist discipline. Use on "renovate", "chart bump", "image update", "Version erhoehen", or any dependency-update PR.
targets: ["*"]
---

# Dependency bumps (Renovate & friends)

All paths are repo-root-relative.

1. Read the bump: which chart/image, which app dir under `apps/` or which
   component under `infrastructure/`?
2. Bump the **source of truth** — the `helmCharts:` entry, `values.yaml`, or
   the `image-ref.txt` used by a contract recipe. Never patch only a rendered
   file; it is not committed and will drift.
3. Inspect the **rendered** manifests of every affected overlay
   (`bash scripts/render.sh <dir>`, inside `nix develop`). Charts can silently
   ignore a value key not in their schema, or ship an HPA that voids
   `replicaCount` — Collabora scaled to 55 replicas and took the cluster down
   (`docs/learnings/collabora-hpa-runaway.md`). For a structured audit use the
   `manifest-inspector` subagent.
4. Contract checks CI will also run — fix here, don't wait for red CI:
   - HPA: none unless allowlisted (`scripts/ci/check-hpa.sh`,
     `scripts/ci/known-gaps/hpa-allowlist.txt`); never autoscale on memory.
   - Database CRs keep pinned images and `spec.resources`
     (`scripts/ci/known-gaps/missing-resources.txt`,
     `unpinned-images.txt` — legacy exceptions only, no new entries).
   - No `:latest`, no `imagePullPolicy: Always`.
5. Run `just validate` before opening or updating the PR.
6. Chart **major** bumps: read the upstream migration notes first. If the bump
   needs a manual cluster or DB migration step, add a `docs/learnings/` entry
   (skill `write-learning`) and update `docs/PRODUCTION-READINESS.md`.
