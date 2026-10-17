# Hermes LiteLLM Integration Implementation Plan

> **Status:** Ersetzt durch ADR 0006. Nicht ausfuehren. Ein neuer
> Implementierungsplan wird nach der schriftlichen Freigabe von ADR 0006 erstellt.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manage Hermes' LiteLLM provider through central Ansible, activate `hermes-balanced` only after gateway acceptance, and retain `openai-codex` with `gpt-5.6-sol` as the tested rollback path.

**Architecture:** The `hermes_agent` role installs a root-owned managed configuration layer and a root-readable/group-Hermes environment file under `/etc/hermes`. The role probes the accepted gateway before changing configuration, validates Hermes' effective merged configuration after templating, and removes only its managed files when disabled. Provider credentials remain in Kubernetes; `hermes01` receives only the rotated LiteLLM master key through Ansible Vault.

**Tech Stack:** Ansible, Ansible Vault, Hermes Agent CLI, systemd user services, LiteLLM OpenAI-compatible API, Nextcloud Talk

**Spec:** `docs/decisions/0005-litellm-hermes-ai-gateway.md`

## Global Constraints

- Execute this plan in the Git repository at `cfgmgmt01:/etc/ansible`, not in the GitOps worktree.
- Do not activate the host variable until every gateway-plan acceptance item, including key rotation, has passed.
- Commit role support disabled first; commit host activation separately.
- Never print, diff, document, or pass the LiteLLM master key in a command argument.
- Use the exact rotated key already stored in the cluster SOPS Secret; do not independently generate another key.
- Keep `openai-codex` and `gpt-5.6-sol` as the final client-side fallback and rollback state.
- Keep transport `chat_completions`; do not add an unmeasured client timeout or guessed Hermes configuration key.
- Provider backend keys must never be copied to `hermes01`.
- Run syntax check, targeted check mode, targeted rollout, and an idempotent second run.
- Stage only this plan's files and copy final operating documentation to `/root/ansible/kellerio-docs/`.

## Review Focus

- The managed deep merge must replace the old Codex base URL and API mode rather than retaining them under the LiteLLM provider; Task 1 owns the effective-config assertions.
- A missing, malformed, or rejected master key must fail before either managed file changes; Tasks 1-2 own these checks.
- Check mode, diff output, task results, and logs must never expose the master key or Authorization header; Tasks 1-2 own these checks.
- Disabling the feature must remove only `/etc/hermes/config.yaml` and `/etc/hermes/.env` and restore the untouched Codex configuration; Task 4 owns this test.
- The restart handler must always have the Hermes UID available, including rollback runs; Task 1 owns the `getent` ordering test.

## File Map

- `roles/hermes_agent/defaults/main.yml`: disabled defaults and LiteLLM provider settings.
- `roles/hermes_agent/tasks/litellm.yml`: preflight, managed files, effective-config assertions, and disable path.
- `roles/hermes_agent/tasks/main.yml`: ordered inclusion after Hermes ownership checks.
- `roles/hermes_agent/templates/hermes-managed-config.yaml.j2`: managed provider, model, endpoint, transport, and fallback.
- `roles/hermes_agent/templates/hermes-managed.env.j2`: only `LITELLM_MASTER_KEY`.
- `roles/hermes_agent/README.md`: role variables, precedence, fallback, and secret boundary.
- `host_vars/hermes01.yml`: encrypted rotated master key and activation flag.
- `README_hermes_litellm_gateway_2026-10-10.md`: deployment, verification, rotation, and rollback record.

---

### Task 1: Add Disabled LiteLLM Role Support

**Files:**
- Modify: `roles/hermes_agent/defaults/main.yml`
- Modify: `roles/hermes_agent/tasks/main.yml`
- Create: `roles/hermes_agent/tasks/litellm.yml`
- Create: `roles/hermes_agent/templates/hermes-managed-config.yaml.j2`
- Create: `roles/hermes_agent/templates/hermes-managed.env.j2`
- Modify: `roles/hermes_agent/README.md`

**Interfaces:**
- Consumes: existing `Restart Hermes gateway` handler, Hermes user ownership checks, and current CLI shape on `hermes01`.
- Produces: `hermes_agent_litellm_enabled`, provider/model/base URL/master-key variables, `/etc/hermes/config.yaml`, and `/etc/hermes/.env`.

- [ ] **Step 1: Capture the current rollback baseline read-only**

Run the existing Hermes CLI as user `hermes` to read `model`, `providers`, and `fallback_providers` as JSON. Confirm the current effective default is `openai-codex` with `gpt-5.6-sol`; do not read or print authentication files.

- [ ] **Step 2: Add disabled defaults**

Add these values without changing host behavior:

```yaml
hermes_agent_litellm_enabled: false
hermes_agent_litellm_base_url: https://litellm.jit.services/v1
hermes_agent_litellm_model: hermes-balanced
hermes_agent_litellm_master_key: >-
  {{ vault_hermes_agent_litellm_master_key | default('') }}
hermes_agent_litellm_fallback_provider: openai-codex
hermes_agent_litellm_fallback_model: gpt-5.6-sol
```

- [ ] **Step 3: Write the managed templates**

Render provider `litellm` with `api`, `key_env: LITELLM_MASTER_KEY`, `transport: chat_completions`, and `default_model: hermes-balanced`. Render `model.provider: custom:litellm`, `model.default: hermes-balanced`, `model.base_url`, and `model.api_mode: chat_completions`. Render one fallback entry for `openai-codex`/`gpt-5.6-sol`.

Use template variables with `to_json` for scalar quoting. The environment template contains only `LITELLM_MASTER_KEY={{ hermes_agent_litellm_master_key }}`.

- [ ] **Step 4: Implement preflight and managed-file behavior**

In `litellm.yml`, look up the Hermes account with `ansible.builtin.getent` before any task that can notify the restart handler. When enabled, assert a newline-free key matching `^sk-[0-9a-f]{64}$`, then probe `GET {{ hermes_agent_litellm_base_url }}/models` from `hermes01` with bearer auth before changing files.

Require HTTP 200 and model `hermes-balanced`. Skip the network probe in check mode. Mark the probe and secret-template task `no_log: true`; set `diff: false` on the secret template.

Create `/etc/hermes` as `root:root` mode `0755`, config as `root:root` mode `0644`, and `.env` as `root:hermes` mode `0640`. Notify the existing restart handler only when a managed file changes.

When disabled, remove only `/etc/hermes/config.yaml` and `/etc/hermes/.env`; leave the directory and user-owned Hermes files untouched.

- [ ] **Step 5: Assert the effective merged configuration**

After templating, run `hermes config check` as `hermes`, then read `model`, `providers`, and `fallback_providers` with `hermes config get ... --json`. Assert exact provider, model, base URL, API mode, transport, key environment variable name, and fallback. Do not expose environment values.

- [ ] **Step 6: Include the task at the safe point**

Include `litellm.yml` immediately after the Hermes ownership assertion and before tasks that modify the user's environment or MCP configuration. Preserve all existing task order outside this insertion.

- [ ] **Step 7: Run role checks with the feature disabled**

Run from `/etc/ansible`:

```bash
git branch --show-current
git diff --check
scripts/lint.sh roles/hermes_agent playbooks/hermes01.yml
ansible-playbook playbooks/hermes01.yml --syntax-check
ansible-playbook playbooks/hermes01.yml \
  --limit hermes01 --tags hermes_agent --check --diff
```

Expected: syntax/lint pass, no secret output, and disabled defaults do not change the existing Hermes provider.

- [ ] **Step 8: Commit disabled support**

```bash
git add roles/hermes_agent/defaults/main.yml roles/hermes_agent/tasks/main.yml \
  roles/hermes_agent/tasks/litellm.yml \
  roles/hermes_agent/templates/hermes-managed-config.yaml.j2 \
  roles/hermes_agent/templates/hermes-managed.env.j2 roles/hermes_agent/README.md
git commit -m "hermes_agent: manage LiteLLM provider"
```

### Task 2: Add the Encrypted Host Activation

**Files:**
- Modify: `host_vars/hermes01.yml`
- Create: `README_hermes_litellm_gateway_2026-10-10.md`

**Interfaces:**
- Consumes: the rotated cluster master key from gateway Task 8 and accepted endpoint `https://litellm.jit.services/v1`.
- Produces: encrypted `vault_hermes_agent_litellm_master_key` and `hermes_agent_litellm_enabled: true` for `hermes01`.

- [ ] **Step 1: Reconfirm all gateway gates**

Require ArgoCD `Synced`/`Healthy`, valid TLS, source/XFF/path/method/limit tests, FQDN/SNI isolation, all three deployment IDs, provider compatibility, distinct failover, and successful key rotation. Stop if any item is absent.

- [ ] **Step 2: Transfer the rotated key without plaintext artifacts**

Use protected interactive input with `ansible-vault encrypt_string --encrypt-vault-id default`. Never place the key in a command argument, plaintext file, shell history, diff, or documentation. Add only the resulting Vault block and the activation boolean to `host_vars/hermes01.yml`.

- [ ] **Step 3: Write the operating record without secrets**

Document dependencies, secure handoff, targeted commands, runtime checks, the ADR rotation order, and rollback. State that backend provider keys remain cluster-only and Codex OAuth remains in `~/.hermes/auth.json`.

- [ ] **Step 4: Prove the repository contains no plaintext key**

Run the repository's Vault/lint checks and inspect `git diff` with secret values hidden. Require a Vault ciphertext block and no key-like plaintext.

- [ ] **Step 5: Run syntax check and targeted check mode**

```bash
ansible-playbook playbooks/hermes01.yml --syntax-check
ansible-playbook playbooks/hermes01.yml \
  --limit hermes01 --tags hermes_agent --check --diff
```

Expected: preflight is skipped only because of check mode, planned non-secret config is visible, the secret template is hidden, and no task fails.

- [ ] **Step 6: Commit activation separately**

```bash
git add host_vars/hermes01.yml README_hermes_litellm_gateway_2026-10-10.md
git commit -m "hermes01: route Hermes through LiteLLM gateway"
```

### Task 3: Roll Out and Verify Hermes End to End

**Files:**
- Modify: `README_hermes_litellm_gateway_2026-10-10.md`

**Interfaces:**
- Consumes: committed activation and a healthy gateway.
- Produces: an idempotent Hermes rollout and a successful bounded Nextcloud Talk tool-call test.

- [ ] **Step 1: Run the targeted deployment**

```bash
ansible-playbook playbooks/hermes01.yml \
  --limit hermes01 --tags hermes_agent --diff
```

Expected: only intended Hermes managed files and service state change; no secret is displayed.

- [ ] **Step 2: Run the idempotence pass**

Run the identical playbook command again.

Expected: `changed=0`, `failed=0`.

- [ ] **Step 3: Validate effective configuration and service state**

Run as `hermes`:

```bash
/home/hermes/.local/bin/hermes config check
/home/hermes/.local/bin/hermes config get model --json
/home/hermes/.local/bin/hermes config get providers --json
/home/hermes/.local/bin/hermes config get fallback_providers --json
/home/hermes/.local/bin/hermes fallback list
/home/hermes/.local/bin/hermes gateway status
```

Expected: `custom:litellm`, `hermes-balanced`, the LiteLLM base URL, chat-completions mode, and final `openai-codex` fallback are all effective.

- [ ] **Step 4: Test Nextcloud Talk with a read-only tool call**

Send one non-sensitive bounded request through the existing Talk conversation that requires an allowed read-only tool. Confirm the response completes and the tool result is usable. Inspect logs for errors without copying prompts or responses into the operating record.

- [ ] **Step 5: Confirm gateway-side routing metadata**

Confirm the request reached `hermes-balanced` and produced a stable deployment ID. Do not require a specific provider on a single random request.

- [ ] **Step 6: Update and copy operating documentation**

Record rollout date, commit, idempotence result, effective provider/model, and test status. Copy the file to `/root/ansible/kellerio-docs/`.

- [ ] **Step 7: Commit only the evidence update**

```bash
git add README_hermes_litellm_gateway_2026-10-10.md
git commit -m "docs(hermes): record LiteLLM rollout"
```

### Task 4: Exercise Rollback and Restore LiteLLM

**Files:**
- Modify: `host_vars/hermes01.yml`
- Modify: `README_hermes_litellm_gateway_2026-10-10.md`

**Interfaces:**
- Consumes: active managed LiteLLM provider and unchanged user-owned Codex configuration.
- Produces: evidence that disabling management restores Codex, followed by a clean reactivation.

- [ ] **Step 1: Disable only the managed LiteLLM layer**

Set `hermes_agent_litellm_enabled: false` without deleting the Vault ciphertext. Run syntax check and targeted check mode, then deploy.

- [ ] **Step 2: Verify rollback behavior**

Require `/etc/hermes/config.yaml` and `/etc/hermes/.env` absent. Require user-owned files unchanged. Run effective-config checks and confirm `openai-codex`, `gpt-5.6-sol`, and the Codex endpoint are active. Send one bounded Talk test.

- [ ] **Step 3: Run the rollback idempotence pass**

Run the targeted playbook again.

Expected: `changed=0`, `failed=0`.

- [ ] **Step 4: Reactivate LiteLLM through the same path**

Set the boolean true, run check mode, deploy, run the idempotence pass, and repeat the effective-config and Talk checks from Task 3.

- [ ] **Step 5: Document the drill and commit final state**

Record rollback and reactivation evidence, with no secrets or content. Ensure the committed final state is enabled.

```bash
git add host_vars/hermes01.yml README_hermes_litellm_gateway_2026-10-10.md
git commit -m "test(hermes): verify LiteLLM rollback path"
```

- [ ] **Step 6: Run final repository verification**

```bash
git diff --check
scripts/lint.sh roles/hermes_agent playbooks/hermes01.yml
ansible-playbook playbooks/hermes01.yml --syntax-check
ansible-playbook playbooks/hermes01.yml \
  --limit hermes01 --tags hermes_agent --check --diff
git status --short
```

Expected: checks pass, the final targeted check predicts no change, and the worktree is clean.
