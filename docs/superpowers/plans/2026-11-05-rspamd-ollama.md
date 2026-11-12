# Rspamd Ollama Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a disabled-by-default, reproducibly pinned local Ollama/Qwen backend for the built-in Rspamd GPT module on `spam01` and `spam02`, then document the gated rollout.

**Architecture:** The external Ansible repository installs one loopback-only Ollama instance per scanner and the existing Rspamd role renders GPT and score configuration. This GitOps repository receives only the durable ADR, runbook, readiness state, and links because no Kubernetes workload is introduced.

**Tech Stack:** Ansible, systemd, Ollama native API, Rspamd 4.1 GPT module, UCL, Redis cache, shell/Python contract tests, Markdown.

**Spec:** `docs/superpowers/specs/2026-11-05-rspamd-ollama-design.md`

## Global Constraints

- Work in `/home/ingo/ansible/cfgmgmt-rspamd-ollama` on branch `feat/rspamd-ollama` for Ansible changes and in the current `kubernetes-gitops` feature worktree for documentation changes.
- Commit every independently reviewed task; never mix the two repositories in one commit.
- Keep `rspamd_ollama_enabled: false` in both production playbooks until both hosts pass the benchmark and resource gates.
- Pin Ollama `v0.40.14` archive SHA-256 to `993e83d08c3d13d17c55009a3e2664c8a25445e644aec3a68bef5abb6abce67d`.
- Pin `qwen3:8b` manifest digest to `sha256:500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41` and model blob digest to `sha256:a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f`.
- Bind Ollama only to `127.0.0.1:11434`; disable cloud access; allow one loaded model and one parallel request.
- Keep GPT `autolearn`, `allow_ham`, `allow_passthrough`, JSON mode, and reason headers disabled.
- Keep all GPT symbol weights at 0 in the committed production playbooks; later activation of `GPT_SPAM` is a separate reviewed change capped at +3.
- Preserve `task_timeout = 8s` while disabled; use 25 seconds only when GPT is enabled so its 20-second request cap can finish.
- Never enable Rspamd GPT debug logging because it logs message content and model responses.
- Do not mutate either production host during code implementation or validation.

## Review Focus

- A mutable `qwen3:8b` tag must be rejected before pull when its remote manifest digest differs, and the local manifest must be verified after pull.
- Disabled mode must not download Ollama, start a service, change the 8-second Rspamd task timeout, or contribute any GPT score.
- A failed or overloaded local Ollama must leave normal Rspamd scanning operational without retries.
- The systemd unit must not expose port 11434 beyond loopback or permit cloud-backed Ollama features.
- GPT Ham and category outputs must remain score-neutral even after the module is enabled for shadow evaluation.

---

### Task 1: Add Ansible Contract Tests

**Files:**
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/scripts/test-rspamd-ollama.py`

**Interfaces:**
- Consumes: The exact constants and invariants in the spec.
- Produces: A standalone `python3 scripts/test-rspamd-ollama.py` contract gate used by every later Ansible task.

- [ ] **Step 1: Write failing tests for the complete role contract**

Cover pinned release/model digests, disabled defaults, disabled-mode stop/disable of an existing unit, loopback-only service, cloud disablement, CPU/RAM limits, `MemAvailable` reserve preflight, pre/post model digest checks, GPT request fields, disabled GPT cache, GPT group `max_score = 3`, timeout relationship, score neutrality, playbook ordering, and explicit disabled production flags.

- [ ] **Step 2: Run the test and verify it fails**

Run: `python3 scripts/test-rspamd-ollama.py`
Expected: FAIL because the role and templates do not exist.

- [ ] **Step 3: Commit the failing contract**

```bash
git add scripts/test-rspamd-ollama.py
git commit -m "test(rspamd): define Ollama integration contract"
```

### Task 2: Add the Pinned Ollama Runtime Role

**Files:**
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd_ollama/defaults/main.yml`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd_ollama/tasks/main.yml`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd_ollama/handlers/main.yml`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd_ollama/templates/ollama.service.j2`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd_ollama/README.md`

**Interfaces:**
- Consumes: `rspamd_ollama_enabled` and pinned constants from Task 1.
- Produces: A role that installs Ollama, hardens its service, verifies host capacity and model digests, pulls and prewarms the model only when enabled.

- [ ] **Step 1: Implement disabled defaults and exact pins**

Define the enabled flag, archive URL/checksum, model name/digests, `127.0.0.1:11434`, 4-CPU/8-GiB limits, one parallel request, one model, queue size 2, and 4096-token context.

- [ ] **Step 2: Implement guarded preflight and installation tasks**

When enabled, assert Debian x86_64, at least 4 vCPU, AVX2, at least 10 GiB total RAM, and before every service start `MemAvailable` of at least the 8-GiB Ollama limit plus 20 percent of total RAM (the same reserve as the benchmark gate); then download/unarchive the pinned artifact, create the unprivileged account and model directory, and enable the service.

When disabled, no download, install, account, or model task runs. The only disabled-mode tasks stop and disable `ollama.service` if its unit file already exists, so a rollback releases resources; on a host that never had Ollama they are no-ops.

- [ ] **Step 3: Implement remote and local model digest verification**

Verify the registry `ollama-content-digest` before pull, pull only if the local manifest is absent or differs, then SHA-256 the local manifest and assert the exact expected digest.

- [ ] **Step 4: Implement readiness and prewarm**

Wait for `/api/tags`, issue a non-content prewarm request with `keep_alive = -1`, and avoid logging response bodies.

- [ ] **Step 5: Run the focused contract test**

Run: `python3 scripts/test-rspamd-ollama.py`
Expected: Runtime-role assertions PASS; GPT/playbook assertions still FAIL.

- [ ] **Step 6: Commit**

```bash
git add roles/rspamd_ollama scripts/test-rspamd-ollama.py
git commit -m "feat(rspamd): add pinned local Ollama runtime"
```

### Task 3: Configure the Built-in Rspamd GPT Module

**Files:**
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd/defaults/main.yml`
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd/tasks/configure_rspamd.yml`
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd/templates/options.inc.j2`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd/templates/gpt.conf.j2`
- Create: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/roles/rspamd/templates/gpt_group.conf.j2`

**Interfaces:**
- Consumes: The shared `rspamd_ollama_enabled` and model name from Task 2.
- Produces: `/etc/rspamd/local.d/gpt.conf`, neutral GPT group weights, and an 8s/25s task-timeout switch.

- [ ] **Step 1: Add GPT and timeout defaults**

Define 20s request timeout, 1s connect timeout, 1000 input tokens, 4096 context tokens, 64 output tokens, disabled thinking, seed 42, and all symbol scores 0.

- [ ] **Step 2: Render the built-in GPT module configuration**

Use `type = "ollama"`, `http://127.0.0.1:11434/api/chat`, plain output, no autolearn, no ham/passthrough expansion, no reason header, `keep_alive = -1`, and Ollama-native nested `options`. Disable the GPT response cache: the 4.1.0 cache key omits subject and sender, and the module falls back to the global Redis servers, so the contract test must prove that `gpt` creates no cache context.

- [ ] **Step 3: Render score overrides**

Set `GPT_SPAM`, `GPT_HAM`, `GPT_MARKETING`, `GPT_PHISHING`, `GPT_SCAM`, `GPT_MALWARE`, and `GPT_UNCERTAIN` to the configured values, all 0 in this change. Give the GPT symbol group `max_score = 3`, because 4.1.0 does not clamp plain-text probabilities to 0..1 and a reply of `3` would otherwise yield factor 5.

- [ ] **Step 4: Make task timeout conditional**

Render `task_timeout = 8s` while disabled and `task_timeout = 25s` while enabled.

- [ ] **Step 5: Run the focused contract test**

Run: `python3 scripts/test-rspamd-ollama.py`
Expected: Role and GPT assertions PASS; playbook assertions still FAIL.

- [ ] **Step 6: Commit**

```bash
git add roles/rspamd scripts/test-rspamd-ollama.py
git commit -m "feat(rspamd): configure local GPT classification"
```

### Task 4: Wire Both Scanner Playbooks Safely

**Files:**
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/playbooks/spam01.yml`
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/playbooks/spam02.yml`
- Modify: `/home/ingo/ansible/cfgmgmt-rspamd-ollama/README_mail_rspamd_setup.md`

**Interfaces:**
- Consumes: `rspamd_ollama` and `rspamd` roles from Tasks 2-3.
- Produces: Identical, explicitly disabled production wiring on both scanners and operator documentation.

- [ ] **Step 1: Add role ordering and explicit flags**

Place `rspamd_ollama` immediately before `rspamd` on both scanners and set `rspamd_ollama_enabled: false` plus all GPT scores to 0 in both playbooks.

- [ ] **Step 2: Document preflight, enablement, benchmark, shadow mode, and rollback**

Extend `README_mail_rspamd_setup.md` with exact commands and acceptance gates without claiming that `spam02` has passed them.

- [ ] **Step 3: Run the complete contract and syntax checks**

Run: `python3 scripts/test-rspamd-ollama.py`
Expected: PASS.

Run: `ANSIBLE_CONFIG=/dev/null ansible-playbook -i localhost, --syntax-check roles/rspamd/tests/test.yml`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add playbooks/spam01.yml playbooks/spam02.yml README_mail_rspamd_setup.md scripts/test-rspamd-ollama.py
git commit -m "feat(rspamd): wire Ollama shadow rollout"
```

### Task 5: Record the External-Mail Operational Contract

**Files:**
- Create: `docs/decisions/0010-rspamd-ollama-integration.md`
- Create: `docs/runbooks/rspamd-ollama-integration.md`
- Modify: `docs/runbooks/README.md`
- Modify: `docs/PRODUCTION-READINESS.md`

**Interfaces:**
- Consumes: The implemented Ansible behavior and validation evidence from Tasks 1-4.
- Produces: Durable ownership, rollout, acceptance, and rollback documentation in the GitOps repository.

- [ ] **Step 1: Add the ADR**

Record the local-per-scanner architecture, no-Kubernetes decision, exact pinned versions, privacy boundary, score policy, timeout coupling, and alternatives rejected.

- [ ] **Step 2: Add and index the runbook**

Document read-only preflight, Ansible check/diff, model benchmark, shadow observations, SMTP-after-DATA acceptance, rollback, and the operational-document copy target.

- [ ] **Step 3: Update production readiness**

The unchecked gates were added together with the design. Update them with the implemented evidence and keep each gate unchecked until it has passed.

- [ ] **Step 4: Run repository validation**

Run: `nix develop --command just validate`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/decisions/0010-rspamd-ollama-integration.md docs/runbooks/rspamd-ollama-integration.md docs/runbooks/README.md docs/PRODUCTION-READINESS.md
git commit -m "docs(rspamd): define local Ollama rollout"
```

### Task 6: Final Cross-Repository Verification

**Files:**
- Verify only; no expected source edits.

**Interfaces:**
- Consumes: All Ansible and GitOps commits.
- Produces: Review evidence that both repositories implement the same disabled-by-default contract.

- [ ] **Step 1: Verify clean worktrees and commit history**

Run `git status --short --branch` and `git log --oneline` in both worktrees. Expected: clean feature branches with task-specific commits.

- [ ] **Step 2: Run all offline checks again**

Run the Ansible contract/syntax checks and `nix develop --command just validate`. Expected: PASS without contacting or mutating production hosts.

- [ ] **Step 3: Review the full branch diffs**

Review Ansible against `origin/master` and GitOps against `origin/main`, with special attention to disabled defaults, mutable tags, loopback exposure, score neutrality, and timeout behavior.
