# Hermes LiteLLM Blablador Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage LiteLLM/Blablador as Hermess primary model path through central Ansible while retaining the existing `openai-codex` OAuth provider as the automatic fallback and rollback state.

**Architecture:** The `hermes_agent` role installs a root-owned managed config layer and a root-readable/group-Hermes env file under `/etc/hermes`. It probes the accepted gateway before writing, validates the merged Hermes config, sets one-attempt/zero-recovery fail-fast behavior, and declares exactly one native Codex fallback. The Blablador key stays cluster-only; Hermes receives only the rotated LiteLLM master key.

**Tech Stack:** Ansible, Ansible Vault, Hermes Agent CLI/config merge, systemd user services, LiteLLM OpenAI-compatible API, Nextcloud Talk

**Spec:** `docs/decisions/0006-litellm-blablador-hermes-codex-fallback.md`

## Global Constraints

- Execute this plan on cfgmgmt01 with `/etc/ansible` as the source repository, not in the GitOps worktree.
- Treat the dirty `/etc/ansible` checkout only as the source repository: create an isolated worktree from current `master`, verify the task-owned files are clean there, and never stage unrelated central changes.
- Do not start until gateway plan Task 8, including key rotation, is accepted.
- Pin Hermes Agent `v0.21.5+6827.g819cc3c` / `819cc3cbe02104c420ea32f1f1a924247d42eaf8` for this rollout; if the installed commit differs, stop and revalidate the managed-scope, provider, retry, and fallback contracts before editing Ansible.
- Commit disabled role support first and host activation separately.
- Never print, diff, document, or pass the LiteLLM master key or Codex tokens in command arguments.
- Use the exact rotated gateway key already stored in the cluster SOPS Secret; do not generate another key.
- Set the primary model to `hermes-blablador` through `https://litellm.jit.services/v1` with Chat Completions.
- Keep `openai-codex` and `gpt-5.6-sol` as the only `fallback_providers` entry and rollback state.
- Set Hermes app-level retry to one attempt and auto-recovery cycles to zero; do not add another retry layer.
- Never copy `BLABLADOR_API_KEY` or Codex OAuth material to managed Ansible files.
- Run syntax check, targeted check mode, targeted rollout, and an idempotent second run.
- Stage only this plan's files and copy final operating documentation to `/root/ansible/kellerio-docs/`.

## Review Focus

- The native `/etc/hermes` managed overlay must replace Codex's primary base URL/API mode while retaining Codex only in `fallback_providers`; Task 1 owns source-contract and effective-config assertions.
- Missing/malformed/rejected master keys must fail before managed files change, and check/diff/log output must never expose credentials; Tasks 1-2 own these tests.
- `api_max_retries: 1` and `auto_recovery_cycles: 0` must land under the installed Hermes schema and survive config merge; Tasks 1 and 3 own this check.
- A controlled gateway 429 must visibly activate Codex for one turn, and the next turn after rate recovery must return to Blablador; Task 3 owns this test.
- Disabling management must remove only `/etc/hermes/config.yaml` and `/etc/hermes/.env`, restore untouched Codex primary state, and remain idempotent; Task 4 owns this test.

## File Map

- `roles/hermes_agent/defaults/main.yml`: disabled defaults, gateway model/URL, fallback, and retry settings.
- `roles/hermes_agent/tasks/litellm.yml`: version/source preflight, managed directory/files, effective-config assertions, and disable path.
- `roles/hermes_agent/tasks/main.yml`: ordered include after Hermes ownership checks.
- `roles/hermes_agent/templates/hermes-managed-config.yaml.j2`: primary custom provider, retry behavior, and Codex fallback.
- `roles/hermes_agent/templates/hermes-managed.env.j2`: only `LITELLM_MASTER_KEY`.
- `roles/hermes_agent/README.md`: variables, merge behavior, secret boundary, failover, and rollback.
- `host_vars/hermes01.yml`: encrypted rotated master key and activation flag.
- `README_hermes_litellm_blablador_2026-10-12.md`: deployment, failover, rotation, and rollback record.

---

### Task 1: Add Disabled LiteLLM/Blablador Role Support

**Files:**
- Modify: `roles/hermes_agent/defaults/main.yml`
- Modify: `roles/hermes_agent/tasks/main.yml`
- Create: `roles/hermes_agent/tasks/litellm.yml`
- Create: `roles/hermes_agent/templates/hermes-managed-config.yaml.j2`
- Create: `roles/hermes_agent/templates/hermes-managed.env.j2`
- Modify: `roles/hermes_agent/README.md`

**Interfaces:**
- Consumes: installed Hermes config schema, existing ownership checks/restart handler, and accepted gateway contract.
- Produces: disabled `hermes_agent_litellm_*` variables and managed `/etc/hermes/config.yaml` plus `/etc/hermes/.env` behavior.

- [ ] **Step 1: Create the isolated central-Ansible worktree and capture the rollback baseline**

On cfgmgmt01, create a dedicated feature branch/worktree from current `master`; do not modify the dirty `/etc/ansible` checkout. Confirm all files named by this plan match `master`. As `hermes`, read effective `model`, `providers`, `fallback_providers`, and `agent` retry settings as JSON. Confirm the primary is `openai-codex`/`gpt-5.6-sol` and do not read or print `auth.json`.

- [ ] **Step 2: Pin the installed Hermes schema**

Require installed version `v0.21.5+6827.g819cc3c` and commit `819cc3cbe02104c420ea32f1f1a924247d42eaf8`. From that source, verify `/etc/hermes` discovery, managed `config.yaml` overlay precedence, managed `.env` precedence, exact named-custom-provider keys, `fallback_providers` shape, and paths for `agent.api_max_retries` and `agent.auto_recovery_cycles`. Verify that the retry loop starts at zero, runs while the counter is below the configured value, and therefore treats `1` as one total attempt. Add role assertions for those exact effective paths; do not invent compatibility aliases or update Hermes during this rollout.

- [ ] **Step 3: Add disabled defaults**

Define:

```yaml
hermes_agent_litellm_enabled: false
hermes_agent_litellm_base_url: https://litellm.jit.services/v1
hermes_agent_litellm_model: hermes-blablador
hermes_agent_litellm_master_key: >-
  {{ vault_hermes_agent_litellm_master_key | default('') }}
hermes_agent_litellm_fallback_provider: openai-codex
hermes_agent_litellm_fallback_model: gpt-5.6-sol
hermes_agent_litellm_api_max_retries: 1
hermes_agent_litellm_auto_recovery_cycles: 0
```

- [ ] **Step 4: Write the managed templates**

Render a named LiteLLM custom provider with the accepted base URL, `key_env: LITELLM_MASTER_KEY`, Chat Completions transport, and model `hermes-blablador`. Make it the primary model. Render exactly one Codex fallback and the two agent retry values. Use `to_json` for scalar quoting. The env template contains only `LITELLM_MASTER_KEY={{ hermes_agent_litellm_master_key }}`.

- [ ] **Step 5: Implement fail-closed preflight and disable behavior**

Resolve the Hermes UID before any task can notify restart. When enabled, assert a newline-free `^sk-[0-9a-f]{64}$` key and probe authenticated `GET /models` from `hermes01` before writing files. Require HTTP 200 and exactly `hermes-blablador`. Skip only the network probe in check mode.

Mark probe and secret template `no_log: true`; set secret template `diff: false`. Create `/etc/hermes` as `root:hermes 0750`, write `/etc/hermes/config.yaml` as `root:root 0644`, and write `.env` as `root:hermes 0640`. When disabled, remove only those two managed files and leave the non-secret directory in place.

- [ ] **Step 6: Validate effective merged config after templating**

Run `hermes config check`, then read effective model, providers, fallback chain, and agent retry values as JSON. Assert gateway primary/model/base/transport/key env, exactly one Codex fallback, retries `1`, and recovery `0`. Never expose env values.

- [ ] **Step 7: Include at the safe role point**

Include `litellm.yml` immediately after Hermes ownership/UID assertions and before tasks modifying the user environment or MCP configuration. Preserve all unrelated ordering.

- [ ] **Step 8: Verify disabled behavior and commit**

Run branch/worktree check, `git diff --check`, role lint, playbook syntax check, and targeted `--check --diff` with tag `hermes_agent`. Require no provider change and no secret output.

Commit only the role files with message `hermes_agent: manage LiteLLM Blablador provider`.

### Task 2: Add the Encrypted Host Activation

**Files:**
- Modify: `host_vars/hermes01.yml`
- Create: `README_hermes_litellm_blablador_2026-10-12.md`

**Interfaces:**
- Consumes: rotated accepted gateway key from gateway Task 8 and disabled role support from Task 1.
- Produces: encrypted `vault_hermes_agent_litellm_master_key` and `hermes_agent_litellm_enabled: true`.

- [ ] **Step 1: Reconfirm every gateway gate**

Require ArgoCD health, TLS, source/XFF/path/method/limit tests, Blablador-only FQDN/SNI isolation, provider contract, one-attempt proxy contract, and successful master-key rotation. Stop if any is absent.

- [ ] **Step 2: Transfer only the rotated key securely**

Use protected stdin/interactive input with `ansible-vault encrypt_string --encrypt-vault-id default`. Never put plaintext in argv, a file, history, diff, or documentation. Add only the ciphertext variable and enable flag to `host_vars/hermes01.yml`.

- [ ] **Step 3: Write the non-secret operating record**

Document dependencies, secure handoff, effective config, failover semantics, targeted commands, rotation, and rollback. State that Blablador remains cluster-only and Codex OAuth remains in `~/.hermes/auth.json`.

- [ ] **Step 4: Prove secret hygiene and check mode**

Run repository Vault/lint checks, inspect redacted diff, run syntax check, and targeted `--check --diff`. Require ciphertext only, planned non-secret config visible, secret template hidden, preflight skipped only for check mode, and no failure.

- [ ] **Step 5: Commit activation separately**

```bash
git add host_vars/hermes01.yml README_hermes_litellm_blablador_2026-10-12.md
git commit -m "hermes01: prefer LiteLLM Blablador gateway"
```

### Task 3: Roll Out and Prove Primary/Fallback Behavior

**Files:**
- Modify: `README_hermes_litellm_blablador_2026-10-12.md`

**Interfaces:**
- Consumes: committed activation and accepted gateway.
- Produces: idempotent rollout, successful Blablador turns, controlled Codex fallback, and return-to-primary evidence.

- [ ] **Step 1: Run targeted deployment and idempotence pass**

Run `ansible-playbook playbooks/hermes01.yml --limit hermes01 --tags hermes_agent --diff`, then run it identically again. Require no secret output; second run must report `changed=0`, `failed=0`.

- [ ] **Step 2: Validate effective config and service**

As `hermes`, run config check and JSON reads for model, providers, fallback providers, and agent retry settings, plus fallback list and gateway status. Require LiteLLM/`hermes-blablador` primary, Chat Completions, retries `1`, recovery `0`, and exactly one `openai-codex`/`gpt-5.6-sol` fallback.

- [ ] **Step 3: Test Blablador through the real Talk path**

Send bounded non-sensitive Talk requests that prove normal completion, streaming/liveness, and one allowed read-only tool call. Confirm gateway metadata/logs show `hermes-blablador`, not Codex. Do not copy prompt or response content into the record.

- [ ] **Step 4: Prepare a no-cost 429 on the exact chat route**

As user `hermes` on `hermes01`, source the protected managed env file without printing it, then send policy-invalid authenticated POST requests to `/v1/chat/completions` until the Ingress returns 429. Supply Authorization to curl through config stdin, not argv. Every precursor request must return policy HTTP 400 and produce no Blablador attempt.

- [ ] **Step 5: Prove Codex fallback and return to primary**

Immediately send one dedicated Hermes test turn. Require a visible 429-triggered switch to `openai-codex` and successful completion. After the rate window expires, send another turn and require gateway evidence that Hermes returned to `hermes-blablador`.

- [ ] **Step 6: Record and copy evidence**

Record dates, commits, idempotence, effective non-secret values, status classes, provider transitions, and test status. Copy the record to `/root/ansible/kellerio-docs/`.

- [ ] **Step 7: Commit only evidence**

Commit the operating record with message `docs(hermes): record Blablador gateway rollout`.

### Task 4: Exercise Rollback and Restore Blablador Primary

**Files:**
- Modify: `host_vars/hermes01.yml`
- Modify: `README_hermes_litellm_blablador_2026-10-12.md`

**Interfaces:**
- Consumes: active managed gateway provider and untouched user-owned Codex auth/config.
- Produces: proven Codex rollback, idempotent disable path, and clean Blablador reactivation.

- [ ] **Step 1: Disable only the managed gateway layer**

Set `hermes_agent_litellm_enabled: false` without deleting Vault ciphertext. Run syntax/check mode, then deploy.

- [ ] **Step 2: Verify rollback state**

Require both managed files absent, user-owned Hermes files unchanged, effective primary `openai-codex`/`gpt-5.6-sol`, original Codex endpoint, and one successful bounded Talk turn.

- [ ] **Step 3: Prove rollback idempotence**

Run the targeted playbook again and require `changed=0`, `failed=0`.

- [ ] **Step 4: Reactivate through the same path**

Set the enable flag true, run check mode, deploy, run idempotence, then repeat Task 3's effective config and one primary-path Talk check. Require `hermes-blablador` is primary again.

- [ ] **Step 5: Document and commit final enabled state**

Record rollback/reactivation evidence without content or credentials, copy the updated record to operational docs, and commit only host vars plus record with message `test(hermes): verify Blablador gateway rollback`.

- [ ] **Step 6: Run final repository verification**

Run `git diff --check`, role lint, syntax check, targeted check mode, and `git status --short`. Require clean checks, no predicted change, no secret output, and a clean worktree.
