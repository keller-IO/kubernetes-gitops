---
name: write-learning
description: Document an operational pitfall, incident, or non-obvious behavior in docs/learnings/ and turn checkable patterns into CI guardrails. Use after a tricky fix, an unexpected side effect, a migration surprise, or when the user says "Learning festhalten", "postmortem", or "dokumentiere das".
targets: ["*"]
---

# Learnings & guardrails

All paths are repo-root-relative. The house format and rules live in
`docs/learnings/README.md` and `docs/AGENTS.md`.

1. Create `docs/learnings/<kebab-case-topic>.md` with the four house sections:
   - **What went wrong** — the symptom, with the concrete command/resource.
   - **Why it failed** — the mechanism, not just the observation.
   - **The correct approach** — what to do instead.
   - **Prevention** — which check now catches this.
2. A learning that names a **checkable pattern** (a forbidden field, a missing
   block, an unwanted resource kind) is only half-done as prose — the next agent
   who didn't think to read it will skip it. Add the matching check:
   - `scripts/ci/guardrails.sh` — source-grep checks. Needs no cluster and no
     rendering; keep it that way and don't merge rendering checks into it.
   - `scripts/ci/check-hpa.sh` — the rendering-based check; add new rendered
     invariants here.
   - New exceptions (paths/keys that would fail today) go into
     `scripts/ci/known-gaps/*.txt` as plain lists — never weaken a check.
3. Update `docs/PRODUCTION-READINESS.md` when the learning leaves an open
   operational gap.
4. Verify locally: `just guardrails` (and `just validate` when anything under
   `scripts/ci/` changed).
5. Operational docs are additionally copied to cfgmgmt01:
   `192.168.23.19:/root/ansible/kellerio-docs/`.
