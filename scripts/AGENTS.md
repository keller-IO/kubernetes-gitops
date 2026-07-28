# scripts — AGENTS.md

## Purpose
CI and local helper scripts used by `just` recipes and workflow checks.

## Ownership
Owns shell scripts under `ci/` and future ops helpers.

## Local Contracts
- Scripts must be Bash with `set -euo pipefail`.
- CI scripts must be safe to run locally and in pull requests.
- Mutating cluster commands are forbidden in automation unless the line carries an
  explicit `guardrails: allow-live-mutation` comment and the surrounding script
  documents scope, target, and rollback.
- `guardrails.sh` is source-grep, needs no cluster and no rendering — keep it that way.
  `check-hpa.sh` needs `kustomize`/`helm`/`yq`/`jq` and a ksops stub because it renders
  every overlay; don't merge rendering checks into `guardrails.sh`.
- **Known-gaps allowlists** (`scripts/ci/known-gaps/*.txt`): plain lists of paths/keys
  a check would otherwise fail on today. They exist so a CI gate can go in *now*
  without waiting for every existing violation to be fixed first — every entry is
  documented tech debt, not an accepted design. Shrink them as gaps get fixed; don't
  add an entry without a one-line reason, and don't add one to hide a *new* violation.

## Work Guidance
- Prefer checks that fail before ArgoCD sees unsafe manifests.
- Keep bypasses visible in code comments, not hidden in environment variables.

## Verification
- `just validate`

## Child DOX Index
None.
