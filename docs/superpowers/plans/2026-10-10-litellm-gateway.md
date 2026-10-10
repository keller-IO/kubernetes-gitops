# LiteLLM Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy and accept a hardened, stateless LiteLLM `v1.104.0` gateway that exposes only `hermes-balanced` to `hermes01` and routes evenly across OpenAI, Anthropic, and Blablador.

**Architecture:** A raw-manifest Kustomize app runs one non-root LiteLLM pod behind two exact API routes on the existing NGINX ingress. A custom pre-call callback enforces the shared request contract before routing, while Cilium restricts ingress to the controller and egress to cluster DNS plus the three provider TLS names. Local contract tests exercise request normalization, steady-state selection, and distinct-deployment failover before ArgoCD receives the app.

**Tech Stack:** Kubernetes, Kustomize, ArgoCD, KSOPS/SOPS/age, CiliumNetworkPolicy, NGINX Ingress Controller, Python `unittest`, Podman, Cosign, Skopeo, Trivy, LiteLLM `v1.104.0`

**Spec:** `docs/decisions/0005-litellm-hermes-ai-gateway.md`

## Global Constraints

- Stop before creating manifests until the exact three model IDs and provider data-processing approvals exist.
- Use `ghcr.io/berriai/litellm-non_root:v1.104.0` only after provenance, digest, and vulnerability checks; commit `tag@sha256:digest`, never a floating tag.
- Do not use LiteLLM `1.82.7` or `1.82.8`.
- Run one replica, one Uvicorn worker, `strategy.type: Recreate`, and no PostgreSQL, Redis, PVC, Admin UI, spend tracking, or external callbacks.
- Store all four credentials only in `apps/base/litellm/secret.sops.yaml`; use `sk-` plus 64 lowercase hexadecimal characters for the master key, and never print decrypted values or put them in command arguments.
- Keep `drop_params: false`; do not set `LITELLM_DROP_PARAMS`, deployment-level `drop_params`, `additional_drop_params`, or `LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY`.
- Keep the image defaults `PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries` and `PRISMA_CLI_PATH` unchanged.
- Expose only `POST /v1/chat/completions` and `GET /v1/models`, and authorize the original peer with `$realip_remote_addr == 192.168.2.37`.
- Permit pod egress only to cluster DNS and TCP/443 for `api.openai.com`, `api.anthropic.com`, and `api.blablador.fz-juelich.de`, including matching TLS SNI constraints.
- Make every cluster change through Git and ArgoCD; acceptance commands may inspect live state but must not mutate it.
- Run `nix develop --command just validate` before every GitOps commit and stage only files named by the current task.

## Review Focus

- A LiteLLM normalization or strip-list change must fail the pinned proxy contract test rather than silently bypass request validation; Task 3 owns this test.
- A forged `X-Forwarded-For: 192.168.2.37` from another host must still receive 403; Task 7 owns this test.
- A permitted provider IP with a different TLS SNI, and any unrelated public HTTPS host, must remain unreachable; Task 7 owns this test.
- Two retryable failures must visit three distinct deployment IDs, while context-window/content-policy errors and emitted streams must not switch providers; Tasks 3 and 6 own these tests.
- Secret rotation must replace the pod only after the new Secret syncs, accept the new key, and reject the old key with 401; Task 8 owns this test.

## File Map

- `apps/base/litellm/request_policy_core.py`: dependency-free request snapshot validation.
- `apps/base/litellm/request_policy.py`: LiteLLM `CustomLogger` adapter that returns HTTP 400 on policy violations.
- `apps/base/litellm/test_request_policy.py`: fast standard-library policy tests run by `just test`.
- `apps/base/litellm/test_litellm_contract.py`: tests executed inside the exact LiteLLM image.
- `apps/base/litellm/config.yaml`: three deployments, router settings, callback registration, and admission control.
- `apps/base/litellm/workload.yaml`: Deployment and ClusterIP Service.
- `apps/base/litellm/ingress.yaml`: TLS, exact paths, method/source checks, and request limits.
- `apps/base/litellm/network-policy.yaml`: ingress-controller-only ingress and DNS/FQDN/SNI egress.
- `apps/base/litellm/namespace.yaml`: explicit namespace with restricted Pod Security labels.
- `apps/base/litellm/secret.sops.yaml`: encrypted provider keys and gateway master key.
- `apps/base/litellm/secret-generator.yaml`: KSOPS generator.
- `apps/base/litellm/kustomization.yaml`: base resources and callback/config ConfigMap generation.
- `apps/overlays/main/litellm/kustomization.yaml`: production overlay discovered by the apps ApplicationSet.
- `scripts/ci/check-litellm.sh`: rendered-manifest invariants.
- `docs/runbooks/litellm-hermes-gateway.md`: artifact evidence, rollout, rotation, acceptance, and rollback.

---

### Task 1: Close External Gates and Pin the Toolchain

**Files:**
- Modify: `flake.nix`
- Create: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: provider account access, data-processing approval, and ADR 0005.
- Produces: `VERIFIED_IMAGE_REF` (`tag@sha256:digest`), `OPENAI_LITELLM_MODEL`, `ANTHROPIC_LITELLM_MODEL`, `BLABLADOR_LITELLM_MODEL`, `COMMON_CHAT_PARAMETERS`, and documented verification evidence.

- [ ] **Step 1: Stop if any non-technical gate is missing**

Obtain written approval for all three providers' processing, retention, and training terms. Confirm that the three accounts expose exact models supporting OpenAI Chat Completions semantics, streaming, and Hermes-style tool calls.

- [ ] **Step 2: Verify the current shell is missing the required reproducible tools**

Run: `nix develop --command sh -c 'command -v cosign && command -v skopeo && command -v trivy && command -v yq && command -v podman'`

Expected before the edit: non-zero because at least `cosign`, `skopeo`, `trivy`, or `yq` is absent.

- [ ] **Step 3: Add the implementation tools to `flake.nix`**

Add `cosign`, `skopeo`, `trivy`, `yq-go`, and `podman` to the existing dev-shell package list. Do not add globally installed tools or a second package manager.

- [ ] **Step 4: Verify tag provenance and derive the immutable image reference**

Run inside the dev shell, assigning the non-secret digest locally:

```bash
VERIFIED_DIGEST="$(skopeo inspect \
  docker://ghcr.io/berriai/litellm-non_root:v1.104.0 | jq -r .Digest)"
VERIFIED_IMAGE_REF="ghcr.io/berriai/litellm-non_root:v1.104.0@${VERIFIED_DIGEST}"
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/BerriAI/litellm/' \
  "${VERIFIED_IMAGE_REF}"
trivy image --severity HIGH,CRITICAL --exit-code 1 "${VERIFIED_IMAGE_REF}"
```

Expected: Skopeo reports the digest, Cosign verifies GitHub-issued provenance/signature, and Trivy exits 0. If Cosign has no valid artifact, stop and document the missing provenance instead of weakening verification.

- [ ] **Step 5: Record non-secret immutable inputs**

Write the verified image reference, scan date/result, exact three LiteLLM model strings, and the empirically tested `COMMON_CHAT_PARAMETERS` into the runbook. Record approvals by reference only; never copy credentials, prompts, or provider responses.

- [ ] **Step 6: Verify the toolchain and repository**

Run: `nix develop --command sh -c 'command -v cosign && command -v skopeo && command -v trivy && command -v yq && command -v podman'`

Expected: all five paths print and the command exits 0.

Run: `nix develop --command just validate`

Expected: all existing gates pass.

- [ ] **Step 7: Commit**

```bash
git add flake.nix docs/runbooks/litellm-hermes-gateway.md
git commit -m "chore(litellm): pin gateway supply-chain inputs"
```

### Task 2: Implement the Request Policy Test First

**Files:**
- Create: `apps/base/litellm/request_policy_core.py`
- Create: `apps/base/litellm/request_policy.py`
- Create: `apps/base/litellm/test_request_policy.py`
- Modify: `justfile`

**Interfaces:**
- Consumes: `COMMON_CHAT_PARAMETERS` from Task 1 and the normalized snapshot contract in LiteLLM `v1.104.0`.
- Produces: `PolicyViolation`, `validate_proxy_request(data: Mapping[str, object]) -> None`, `HermesRequestPolicy.async_pre_call_hook(...)`, and `hermes_request_policy`.

- [ ] **Step 1: Write failing core-policy tests**

Create `RequestPolicyTests` with these test methods and assertions:

```python
def test_accepts_exact_model_messages_and_common_parameters(self): ...
def test_rejects_other_model_or_missing_messages(self): ...
def test_rejects_unknown_or_backend_specific_parameter(self): ...
def test_rejects_extra_body_and_routing_retry_drop_timeout_controls(self): ...
def test_rejects_x_litellm_control_header_case_insensitively(self): ...
def test_missing_or_malformed_proxy_snapshot_fails_closed(self): ...
def test_versioned_proxy_injected_fields_are_ignored_without_mutation(self): ...
```

Assert that accepted data is unchanged and every rejected case raises `PolicyViolation` naming keys only, never values.

- [ ] **Step 2: Run the tests and observe the expected failure**

Run: `python3 -m unittest apps/base/litellm/test_request_policy.py -v`

Expected: import failure because `request_policy_core.py` does not yet exist.

- [ ] **Step 3: Implement the dependency-free validator**

Define immutable sets for `COMMON_CHAT_PARAMETERS`, forbidden LiteLLM controls, and the exact `v1.104.0` proxy-injected snapshot fields. Validate `proxy_server_request.body` and cleaned headers; require `model == "hermes-balanced"`, a list-valued `messages`, no unknown provider-directed fields, and no `x-litellm-*` control header. Do not mutate or log the request.

- [ ] **Step 4: Implement the LiteLLM adapter**

Subclass `litellm.integrations.custom_logger.CustomLogger`, set `enforces_request_content = True`, and implement the exact four-argument `async_pre_call_hook`. Translate `PolicyViolation` to `fastapi.HTTPException(status_code=400, detail=...)`; otherwise return the original data unchanged. Export one `hermes_request_policy` instance for `litellm_settings.callbacks`.

- [ ] **Step 5: Add the fast test to `just test` and verify green**

Run: `python3 -m unittest apps/base/litellm/test_request_policy.py -v`

Expected: all request-policy tests pass.

Run: `nix develop --command just validate`

Expected: the new policy test and all repository gates pass.

- [ ] **Step 6: Commit**

```bash
git add justfile apps/base/litellm/request_policy_core.py \
  apps/base/litellm/request_policy.py apps/base/litellm/test_request_policy.py
git commit -m "feat(litellm): enforce Hermes request contract"
```

### Task 3: Pin LiteLLM Normalization and Routing Contracts

**Files:**
- Create: `apps/base/litellm/test_litellm_contract.py`
- Modify: `justfile`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: `VERIFIED_IMAGE_REF`, `hermes_request_policy`, and policy constants from Tasks 1-2.
- Produces: `just litellm-contract`, a version-specific upgrade gate for normalization, distribution, and failover.

- [ ] **Step 1: Write failing image-contract tests**

Use `unittest`, LiteLLM `Router`, FastAPI `TestClient`, and local HTTP stubs. Add tests that assert:

```python
def test_callback_loads_from_config_directory_and_returns_http_400(): ...
def test_proxy_snapshot_matches_the_pinned_injected_field_set(): ...
def test_stripped_callbacks_mock_and_disabled_callback_fields_are_ineffective(): ...
def test_simple_shuffle_selects_each_deployment_between_900_and_1110_times(): ...
def test_two_retryable_failures_visit_three_distinct_deployment_ids(): ...
def test_other_provider_api_error_may_fail_over_to_another_deployment(): ...
def test_context_and_content_policy_errors_do_not_switch_deployments(): ...
def test_stream_does_not_switch_after_the_first_emitted_chunk(): ...
```

Use three stable IDs: `hermes-openai`, `hermes-anthropic`, and `hermes-blablador`. The 3,000-selection test must omit `weight`, `order`, `rpm`, and `tpm`.

- [ ] **Step 2: Add a containerized test recipe and observe failure**

Add `just litellm-contract` that runs the exact `VERIFIED_IMAGE_REF` with `--network=none`, mounts `apps/base/litellm` read-only at `/work`, overrides the entrypoint to Python, and runs only `test_litellm_contract.py`.

Run: `nix develop --command just litellm-contract`

Expected before completing the harness: FAIL on the first unimplemented contract assertion.

- [ ] **Step 3: Complete local stubs and assertions without production credentials**

Run HTTP stubs on container loopback. Return controlled OpenAI-compatible success, 400-class provider API errors, 429, 500, context-window, content-policy, and streaming responses. Record only attempt count and deployment ID in memory; never log message content.

- [ ] **Step 4: Verify the pinned contract**

Run: `nix develop --command just litellm-contract`

Expected: all contract tests pass using LiteLLM `v1.104.0` and no external network.

Document that this recipe must pass before every LiteLLM image upgrade; a changed normalized snapshot or stripped-field behavior blocks the upgrade until the policy and ADR are reviewed.

- [ ] **Step 5: Commit**

```bash
git add justfile apps/base/litellm/test_litellm_contract.py \
  docs/runbooks/litellm-hermes-gateway.md
git commit -m "test(litellm): pin proxy and router contracts"
```

### Task 4: Build the Stateless Runtime and Secret Boundary

**Files:**
- Create: `scripts/ci/check-litellm.sh`
- Create: `apps/base/litellm/namespace.yaml`
- Create: `apps/base/litellm/config.yaml`
- Create: `apps/base/litellm/workload.yaml`
- Create: `apps/base/litellm/secret.sops.yaml`
- Create: `apps/base/litellm/secret-generator.yaml`
- Create: `apps/base/litellm/kustomization.yaml`
- Modify: `justfile`

**Interfaces:**
- Consumes: verified image/model strings from Task 1 and callback files from Task 2.
- Produces: `Deployment/litellm`, `Service/litellm`, `Secret/litellm`, and a rendered-manifest contract check.

- [ ] **Step 1: Write the failing rendered-manifest check**

Create a Bash script with `set -euo pipefail` that renders `apps/base/litellm` and uses `yq` to require:

- one Deployment with one replica, `Recreate`, sync wave `0`, and image `VERIFIED_IMAGE_REF`;
- pod secret revision annotation and `automountServiceAccountToken: false`;
- pod UID/GID `65534`, `RuntimeDefault`, container `allowPrivilegeEscalation: false`, dropped `ALL`, and read-only root filesystem;
- requests `250m`/`512Mi`, limits `1`/`1Gi`;
- bounded `emptyDir` mounts at `/tmp`, `/app/.cache`, and `/app/migrations`;
- no override of `PRISMA_BINARY_CACHE_DIR` or `PRISMA_CLI_PATH`;
- no PVC, database, Redis, HPA, PDB, ServiceMonitor, log sidecar, or second worker;
- Admin UI disabled, message logging redacted, debug logging off, and local cost map enabled;
- one ClusterIP Service on port 4000;
- Secret sync wave `-1` and exactly four expected keys.

Run: `nix develop --command scripts/ci/check-litellm.sh`

Expected: FAIL because the app does not exist.

- [ ] **Step 2: Create the namespace and LiteLLM config**

Set restricted Pod Security labels on namespace `litellm`. Configure exactly three `hermes-balanced` deployments with IDs `hermes-openai`, `hermes-anthropic`, and `hermes-blablador`; keys use `os.environ/...`, and only Blablador sets its explicit API base. Configure `simple-shuffle`, `num_retries: 0`, `enable_weighted_failover: true`, and `max_fallbacks: 2`.

Register `request_policy.hermes_request_policy`, set `drop_params: false`, `turn_off_message_logging: true`, and debug verbosity off. Set admission control to 4 in flight, 4 queued, and 1 second queue timeout. Leave database URL, Redis, callbacks other than the request policy, and wildcard models absent.

- [ ] **Step 3: Create the Deployment and Service**

Mount `config.yaml`, `request_policy.py`, and `request_policy_core.py` read-only from one generated ConfigMap. Pass `--config /app/config/config.yaml --port 4000`; set `NUM_WORKERS=1`, `LITELLM_MODE=PRODUCTION`, `LITELLM_LOCAL_MODEL_COST_MAP=True`, `DISABLE_ADMIN_UI=True`, `NO_DOCS=True`, `NO_REDOC=True`, `NO_OPENAPI=True`, `XDG_CACHE_HOME=/app/.cache`, and `LITELLM_MIGRATION_DIR=/app/migrations`.

Use readiness `/health/readiness` and liveness `/health/liveliness` on named port `http`. Reference all four Secret keys individually. Use bounded `emptyDir` volumes of 64Mi for `/tmp`, 128Mi for `/app/.cache`, and 64Mi for `/app/migrations`.

- [ ] **Step 4: Create and encrypt the Secret**

Create one SOPS-encrypted `Secret/litellm` with sync wave `-1` and these keys only: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `BLABLADOR_API_KEY`, `LITELLM_MASTER_KEY`. Generate the master key as `sk-` plus 64 lowercase hexadecimal characters from 32 random bytes through protected interactive input; never place plaintext in a command argument, temporary repository file, diff, or shell history.

Run: `nix develop --command just secrets-check`

Expected: `secret.sops.yaml` is recognized as encrypted.

- [ ] **Step 5: Wire Kustomize and the static check**

Generate one ConfigMap from the three non-secret files and include the KSOPS generator. Add `scripts/ci/check-litellm.sh` to `just test` after rendering.

- [ ] **Step 6: Verify runtime manifests**

Run: `nix develop --command scripts/ci/check-litellm.sh`

Expected: all runtime and Secret assertions pass.

Run: `nix develop --command just validate`

Expected: lint, encryption, guardrails, rendering, schema checks, and unit tests pass.

- [ ] **Step 7: Commit**

```bash
git add justfile scripts/ci/check-litellm.sh apps/base/litellm
git commit -m "feat(litellm): add stateless gateway runtime"
```

### Task 5: Enforce Ingress and Provider Network Boundaries

**Files:**
- Create: `apps/base/litellm/ingress.yaml`
- Create: `apps/base/litellm/network-policy.yaml`
- Create: `apps/overlays/main/litellm/kustomization.yaml`
- Modify: `apps/base/litellm/kustomization.yaml`
- Modify: `apps/overlays/main/cluster-config.yaml`
- Modify: `scripts/ci/check-litellm.sh`

**Interfaces:**
- Consumes: Service port 4000 from Task 4 and rendered ingress-controller labels.
- Produces: TLS ingress `litellm.jit.services` and a default-deny Cilium policy with explicit ingress and egress allows.

- [ ] **Step 1: Extend the manifest check before adding network resources**

Require exactly two `pathType: Exact` paths, the five ADR rate/body annotations, TLS secret `litellm-tls`, original-peer and method checks in `nginx.org/location-snippets`, ingress only from the rendered NGINX controller labels, DNS only to kube-dns, and provider HTTPS rules containing both `toFQDNs.matchName` and matching `toPorts.serverNames`.

Run: `nix develop --command scripts/ci/check-litellm.sh`

Expected: FAIL because Ingress and CiliumNetworkPolicy are absent.

- [ ] **Step 2: Confirm controller and DNS labels from rendered infrastructure**

Run read-only render queries against `infrastructure/base/ingress-nginx` and the deployed kube-dns objects. Record the exact labels in the runbook and use those labels in the Cilium policy; do not guess selectors.

- [ ] **Step 3: Create the exact-path Ingress**

Use one Ingress with exact paths `/v1/chat/completions` and `/v1/models`. In the shared location snippet, return 403 unless `$realip_remote_addr` is `192.168.2.37`, and return 405 unless `$request_method$uri` is exactly `POST/v1/chat/completions` or `GET/v1/models`.

Set body limit `1m`, rate `30r/m`, burst `10`, no-delay true, and rate key `${realip_remote_addr}`. Use `letsencrypt-prod`, HTTPS redirect, host `litellm.jit.services`, and TLS secret `litellm-tls`.

- [ ] **Step 4: Create the CiliumNetworkPolicy**

Select only the LiteLLM pod. Allow ingress to TCP/4000 only from the ingress-controller endpoint selector. Allow TCP and UDP DNS to kube-dns with L7 DNS names required for the three providers. Allow TCP/443 only through three exact FQDN rules paired with matching `serverNames`. Add no broad CIDR, world, private-network, Link-Local, or metadata exception.

- [ ] **Step 5: Add the main overlay and hostname inventory**

Create the overlay with only the base resource and add `host_litellm: litellm.jit.services` to `cluster-config.yaml`.

- [ ] **Step 6: Verify all static boundaries**

Run: `nix develop --command scripts/ci/check-litellm.sh`

Expected: every ingress and network assertion passes.

Run: `nix develop --command just validate`

Expected: all repository checks pass and the ApplicationSet-discovered overlay renders.

- [ ] **Step 7: Commit**

```bash
git add apps/base/litellm apps/overlays/main/litellm \
  apps/overlays/main/cluster-config.yaml scripts/ci/check-litellm.sh
git commit -m "feat(litellm): restrict gateway ingress and egress"
```

### Task 6: Prove Provider Compatibility Before Cluster Rollout

**Files:**
- Modify: `apps/base/litellm/test_litellm_contract.py`
- Modify: `justfile`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: encrypted provider credentials through protected runtime injection and the exact production config.
- Produces: recorded, non-sensitive evidence that all three providers satisfy chat, streaming, tools, and timeout requirements.

- [ ] **Step 1: Add failing provider-contract cases and a networked opt-in recipe**

Add opt-in tests, skipped unless protected provider environment variables are present, for one ordinary completion, one stream with at least two chunks, and one deterministic tool call per exact model. Assert schema and tool-call shape only; never print content.

Add `just litellm-provider-contract` as a separate recipe using the same immutable image without `--network=none`. Require `LITELLM_PROVIDER_ENV_FILE` to name a mode-0600 file outside the repository; pass only that path to Podman and never display its contents. Keep `just litellm-contract` network-isolated.

- [ ] **Step 2: Run without credentials and verify safe skipping**

Run: `nix develop --command just litellm-contract`

Expected: local contracts pass and provider tests report skipped without leaking environment values.

- [ ] **Step 3: Run with protected credentials outside the repository**

Inject credentials from a mode-0600 environment source that is not tracked and run `nix develop --command just litellm-provider-contract`. Record status, latency, selected deployment ID, stream completion, and tool-call compatibility only.

Expected: every provider passes all three request forms.

- [ ] **Step 4: Derive timeout values from measurements**

Set no gateway/client timeout until measurements show that three sequential attempts fit inside Hermes' observed client limit. If a timeout is needed, add the measured value to `config.yaml`, its assertion to `check-litellm.sh`, and its rationale to the runbook.

- [ ] **Step 5: Verify failover and stream boundaries again**

Run the local real-proxy stub cases for two failures then success, context-window, content-policy, and failure after the first stream chunk. Require three distinct IDs only for the retryable pre-stream chain.

- [ ] **Step 6: Commit any measurement-driven config change**

If no config changed, do not create an empty commit. Otherwise:

```bash
git add apps/base/litellm/config.yaml apps/base/litellm/test_litellm_contract.py \
  scripts/ci/check-litellm.sh docs/runbooks/litellm-hermes-gateway.md
git commit -m "test(litellm): verify provider compatibility"
```

### Task 7: Merge Through GitOps and Run Live Acceptance

**Files:**
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: reviewed GitOps branch, unactivated Hermes client, and read-only cluster access.
- Produces: an ArgoCD `Synced`/`Healthy` gateway with ingress, policy, and provider acceptance evidence.

- [ ] **Step 1: Run final pre-PR verification**

Run: `nix develop --command just validate`

Run: `nix develop --command just litellm-contract`

Run: `git diff --check`

Expected: all commands exit 0.

- [ ] **Step 2: Review rendered secrets without exposing values**

Confirm only Secret metadata and key names, never decoded values. Confirm the Deployment image has the verified tag and digest, and no generated HPA, PVC, database, Redis, or management ingress exists.

- [ ] **Step 3: Merge through the normal PR and wait for ArgoCD**

Do not use mutating `kubectl`. Wait until the `litellm` Application, Deployment, Pod, Certificate, and Ingress are healthy through ArgoCD and read-only Kubernetes queries.

- [ ] **Step 4: Confirm Cilium L7 capability and policy realization**

Read `cilium-config` and Cilium endpoint/policy state. Require `enable-l7-proxy: "true"`, realized DNS proxy rules, the three FQDNs, and the three SNI names before sending provider traffic.

- [ ] **Step 5: Test the external API matrix**

From `hermes01`, require valid-key success only for `POST /v1/chat/completions` and `GET /v1/models`. Require 404 or 405 for appended slashes, child paths, wrong methods, `/`, health, docs, OpenAPI, UI, and management paths. Require 401 for an invalid key.

- [ ] **Step 6: Test source-IP and XFF spoofing**

From a different LAN host, require 403 both normally and with `X-Forwarded-For: 192.168.2.37`. Inspect rendered NGINX configuration read-only and confirm the check uses `$realip_remote_addr`, not `$remote_addr`.

- [ ] **Step 7: Test egress isolation and DNS behavior**

From the LiteLLM network identity, verify the three provider names through their current CNAME chains and IP rotations. Require failure for an unrelated public HTTPS host, all private/Link-Local/metadata targets, and a TLS connection to an allowed provider IP with a different SNI.

- [ ] **Step 8: Test limits and provider behavior**

Require 413 above 1MiB, 429 beyond ingress rate/burst, and 503 when in-flight plus queue capacity is exhausted. Send ordinary, streaming, and tool-calling requests until all three stable deployment IDs have appeared. Record metadata only.

- [ ] **Step 9: Update the runbook evidence**

Record dates, status codes, deployment IDs, latency ranges, ArgoCD revision, and policy results. Do not record keys, prompts, responses, or personal data.

### Task 8: Prove Key Rotation and Close Gateway Readiness

**Files:**
- Modify: `apps/base/litellm/secret.sops.yaml`
- Modify: `apps/base/litellm/workload.yaml`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`
- Modify: `docs/PRODUCTION-READINESS.md`

**Interfaces:**
- Consumes: healthy gateway from Task 7 while Hermes still uses `openai-codex`.
- Produces: a tested second master key ready for the Ansible plan and a closed gateway readiness record.

- [ ] **Step 1: Prepare a second master key securely**

Generate a second value as `sk-` plus 64 lowercase hexadecimal characters from 32 random bytes through protected input, update only the encrypted `LITELLM_MASTER_KEY`, and bump the non-secret pod annotation from revision `v1` to `v2`. Keep the first key available only long enough for the rejection test.

- [ ] **Step 2: Verify sync ordering before merge**

Run: `nix develop --command scripts/ci/check-litellm.sh`

Expected: Secret wave `-1`, Deployment wave `0`, `Recreate`, and pod secret revision `v2` all pass.

Run: `nix develop --command just validate`

Expected: all checks pass and the SOPS file remains encrypted.

- [ ] **Step 3: Commit and merge the rotation through GitOps**

```bash
git add apps/base/litellm/secret.sops.yaml apps/base/litellm/workload.yaml
git commit -m "chore(litellm): rotate gateway master key"
```

Wait for ArgoCD to apply the Secret before replacing the only pod and for the new pod to become Ready.

- [ ] **Step 4: Prove new-key acceptance and old-key rejection**

From `hermes01`, require a valid `/v1/models` response with the second key and HTTP 401 with the first key. Then destroy the first plaintext copy and retain only encrypted/history-safe material.

- [ ] **Step 5: Close documentation and readiness**

Mark the gateway deployed and list only remaining Hermes activation work in `docs/PRODUCTION-READINESS.md`. Complete the runbook's rotation and rollback evidence, then copy it to `cfgmgmt01:/root/ansible/kellerio-docs/`.

- [ ] **Step 6: Final verification and commit**

Run: `nix develop --command just validate`

Run: `git diff --check`

Expected: both exit 0.

```bash
git add docs/runbooks/litellm-hermes-gateway.md docs/PRODUCTION-READINESS.md
git commit -m "docs(litellm): record gateway acceptance"
```

The second key is the only value handed securely to the dependent Hermes/Ansible plan.
