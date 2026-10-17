---
name: write-learning
description: Document an operational pitfall, incident, or non-obvious behavior in docs/learnings/ and turn checkable patterns into CI guardrails. Use after a tricky fix, an unexpected side effect, a migration surprise, or when the user says "Learning festhalten", "postmortem", or "dokumentiere das".
targets: ["*"]
---

# Learnings & guardrails

All paths are repo-root-relative. Read `docs/learnings/README.md`,
`docs/AGENTS.md`, and a relevant existing learning before writing.

1. Create `docs/learnings/<kebab-case-topic>.md` covering the symptom with a
   concrete command/resource, the mechanism, the correction, and prevention.
   Existing learnings use German or English headings suited to the incident;
   there is no mandatory four-heading template.
2. A learning that names a **checkable pattern** (a forbidden field, a missing
   block, an unwanted resource kind) is only half-done as prose — the next agent
   who didn't think to read it will skip it. Add the matching check:
   - `scripts/ci/guardrails.sh` — source-grep checks. Needs no cluster and no
     rendering; keep it that way and don't merge rendering checks into it.
   - `scripts/ci/check-hpa.sh` — the existing rendering-based HPA check. Add
     other rendered invariants to an appropriate CI check.
   - `scripts/ci/known-gaps/*.txt` records existing legacy exceptions with a
     reason. Do not add new violations to an allowlist to make a check pass.
3. Update `docs/PRODUCTION-READINESS.md` when the learning leaves an open
   operational gap.
4. Verify locally: `just guardrails`, the affected rendering-based check when
   applicable, and `just validate` when anything under `scripts/ci/` changed.
5. Operational docs are additionally copied to cfgmgmt01:
   `192.168.23.19:/root/ansible/kellerio-docs/`.
