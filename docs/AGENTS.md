# docs — AGENTS.md

## Purpose
Durable project documentation: production gap-tracking, runbooks, learnings, decisions.

## Ownership
Owns `PRODUCTION-READINESS.md`, `runbooks/`, `learnings/`, `decisions/`.

## Local Contracts
- **Production Readiness**: Single source of truth for open steps. Mandatory update on blueprint edits.
- **Runbooks**: Operational procedures.
- **Learnings**: Distilled pitfalls. A learning that names a checkable pattern (a
  forbidden field, a missing block, an unwanted resource kind) should get a matching
  check in `scripts/ci/guardrails.sh` or `scripts/ci/check-hpa.sh` — prose alone gets
  skipped by the next agent who didn't think to read it.
- **Decisions**: Architecture Decision Records (ADR).

## Work Guidance
- Follow `kubernetes-gitops/AGENTS.md` and Root AGENTS.md.
- Keep placeholders (`CHANGE ME`, `REPLACE_ME`) intact.

## Verification
None.

## Child DOX Index
None.
