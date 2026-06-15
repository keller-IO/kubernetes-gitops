# docs — AGENTS.md

## Purpose

Durable project documentation: production gap-tracking, runbooks, learnings.

## Ownership

Owns `PRODUCTION-READINESS.md`, `runbooks/`, `learnings/`.

## Local Contracts

- `PRODUCTION-READINESS.md` — single source of truth for open go-live steps. MUST stay sorted
  by area, list concrete file paths, carry a `- [ ]` checklist + ≥1 example per section. Update
  it in the same change as any blueprint edit (per-app table = section 14). Full rules: root
  AGENTS.md "Production Readiness Document".
- `runbooks/` — one Markdown per operational procedure (restore, rotation, incident).
- `learnings/` — distilled pitfalls; criteria in root AGENTS.md "Operational Learnings".

## Work Guidance

- Keep placeholders (`CHANGE ME` / `REPLACE_ME`) intact so `grep` finds open spots.

## Verification

None.

## Child DOX Index

None.
