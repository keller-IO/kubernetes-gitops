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

## Work Guidance
- Prefer checks that fail before ArgoCD sees unsafe manifests.
- Keep bypasses visible in code comments, not hidden in environment variables.

## Verification
- `just validate`

## Child DOX Index
None.
