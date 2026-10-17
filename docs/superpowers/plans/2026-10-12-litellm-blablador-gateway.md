# LiteLLM Blablador Gateway Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy and accept a hardened, stateless LiteLLM `v1.104.0` gateway that exposes only `hermes-blablador` to `hermes01` and forwards exactly once to Blablador `alias-code`.

**Architecture:** A raw-manifest Kustomize app runs one non-root LiteLLM pod behind two exact NGINX routes. A custom pre-call callback enforces the Hermes request contract, while Cilium permits only cluster DNS and Blablador HTTPS with matching FQDN and SNI. Provider failover is not part of this plan; the dependent Hermes plan owns the direct Codex-OAuth fallback.

**Tech Stack:** Kubernetes, Kustomize, ArgoCD, KSOPS/SOPS/age, CiliumNetworkPolicy, NGINX Ingress Controller, Python `unittest`, Podman, Cosign, Skopeo, Trivy, LiteLLM `v1.104.0`

**Spec:** `docs/decisions/0006-litellm-blablador-hermes-codex-fallback.md`

## Global Constraints

- Use only Blablador `openai/alias-code`; do not add OpenAI Platform, Anthropic, Codex OAuth, or a second LiteLLM deployment.
- Use `ghcr.io/berriai/litellm-non_root:v1.104.0` only after provenance, digest, and vulnerability checks; commit `tag@sha256:digest`, never a floating tag.
- Do not use LiteLLM `1.82.7` or `1.82.8`.
- Run one replica, one Uvicorn worker, `strategy.type: Recreate`, and no PostgreSQL, Redis, PVC, HPA, PDB, Admin UI, spend tracking, or external callbacks.
- Store only `BLABLADOR_API_KEY` and `LITELLM_MASTER_KEY` in `apps/base/litellm/secret.sops.yaml`; never print decrypted values or put them in command arguments.
- Keep `drop_params: false`; do not set `LITELLM_DROP_PARAMS`, deployment-level `drop_params`, `additional_drop_params`, or `LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY`.
- Keep the image defaults `PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries` and `PRISMA_CLI_PATH` unchanged.
- Expose only `POST /v1/chat/completions` and `GET /v1/models`, and authorize the original peer with `$realip_remote_addr == 192.168.2.37`.
- Permit pod egress only to cluster DNS and TCP/443 for `api.blablador.fz-juelich.de`, including matching TLS SNI.
- Make every cluster change through Git and ArgoCD; acceptance commands may inspect live state but must not mutate it.
- Run `nix develop --command just validate` before every GitOps commit and stage only files named by the current task.

## Review Focus

- A mode other than `0600`, an env file inside the repository, or a missing `BLABLADOR_API_KEY` must stop the networked provider test before Podman starts; Task 2 owns this test.
- A LiteLLM normalization or strip-list change must fail the pinned proxy contract test rather than bypass request validation; Task 4 owns this test.
- Controlled 400, 401, 429, and 5xx upstream responses must make exactly one Blablador attempt and preserve the HTTP status class; Task 4 owns this test.
- A forged `X-Forwarded-For: 192.168.2.37`, a different SNI on an allowed IP, and any unrelated HTTPS host must remain blocked; Task 7 owns these tests.
- Because `alias-code` can change backend without a Git diff, chat, streaming, and deterministic tool calling must pass before rollout and before image/Hermes upgrades; Tasks 2 and 7 own these tests.

## File Map

- `apps/base/litellm/image-ref.txt`: single non-secret source for the verified image used by local contract recipes.
- `apps/base/litellm/test_blablador_contract.py`: opt-in networked provider contract.
- `apps/base/litellm/request_policy_core.py`: dependency-free request snapshot validation.
- `apps/base/litellm/request_policy.py`: LiteLLM `CustomLogger` adapter returning HTTP 400 on violations.
- `apps/base/litellm/test_request_policy.py`: fast standard-library policy tests run by `just test`.
- `apps/base/litellm/test_litellm_contract.py`: tests inside the exact LiteLLM image.
- `apps/base/litellm/config.yaml`: one Blablador deployment, no gateway fallback, callback, and admission control.
- `apps/base/litellm/workload.yaml`: Deployment and ClusterIP Service.
- `apps/base/litellm/ingress.yaml`: TLS, exact paths, method/source checks, and limits.
- `apps/base/litellm/network-policy.yaml`: ingress-controller-only ingress and DNS/FQDN/SNI egress.
- `apps/base/litellm/network_probe.py`: dependency-free allowed/blocked egress assertions.
- `apps/base/litellm/test_network_probe.py`: network-free tests for probe success/failure classification and case coverage.
- `apps/base/litellm/network-policy-probe.yaml`: hardened ArgoCD PostSync Job under the same policy identity.
- `apps/base/litellm/namespace.yaml`: namespace with restricted Pod Security labels.
- `apps/base/litellm/secret.sops.yaml`: encrypted Blablador and gateway keys.
- `apps/base/litellm/secret-generator.yaml`: KSOPS generator.
- `apps/base/litellm/kustomization.yaml`: base resources and generated non-secret ConfigMap.
- `apps/overlays/main/litellm/kustomization.yaml`: production overlay discovered by the Apps ApplicationSet.
- `scripts/ci/check-litellm.sh`: rendered-manifest invariants.
- `docs/runbooks/litellm-hermes-gateway.md`: supply-chain, rollout, rotation, acceptance, and rollback evidence.

---

### Task 1: Pin the Toolchain and LiteLLM Image

**Files:**
- Modify: `flake.nix`
- Create: `apps/base/litellm/image-ref.txt`
- Create: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: ADR 0006 and upstream image `ghcr.io/berriai/litellm-non_root:v1.104.0`.
- Produces: `image-ref.txt` containing one newline-terminated `tag@sha256:digest` and non-secret supply-chain evidence.

- [ ] **Step 1: Confirm the reproducible tools are not all present**

Run:

```bash
nix develop --command sh -c \
  'command -v cosign && command -v skopeo && command -v trivy && command -v yq && command -v podman'
```

Expected before the edit: non-zero because at least one required tool is absent.

- [ ] **Step 2: Add the implementation tools to `flake.nix`**

Add `cosign`, `skopeo`, `trivy`, `yq-go`, and `podman` to the existing dev-shell package list. Do not add a second package manager or globally installed tools.

- [ ] **Step 3: Verify provenance and derive the immutable image reference**

Inside the dev shell, assign the digest and reference only to shell variables, then run:

```bash
VERIFIED_DIGEST="$(skopeo inspect \
  docker://ghcr.io/berriai/litellm-non_root:v1.104.0 | jq -r .Digest)"
VERIFIED_IMAGE_REF="ghcr.io/berriai/litellm-non_root:v1.104.0@${VERIFIED_DIGEST}"
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  "${VERIFIED_IMAGE_REF}"
trivy image --severity HIGH,CRITICAL --exit-code 1 "${VERIFIED_IMAGE_REF}"
```

Expected: non-empty SHA-256 digest, a valid signature and offline Rekor inclusion
against LiteLLM's public Cosign key pinned to source commit
`0112e53046018d726492c814b3644b7d376029d0`, and no unaccepted HIGH/CRITICAL
finding. Upstream `v1.104.0` uses this long-lived key rather than a keyless GitHub
Actions certificate; if this exact signature gate fails, stop rather than weakening
verification.

- [ ] **Step 4: Record the immutable input**

Create `image-ref.txt` containing only `VERIFIED_IMAGE_REF`. Record the digest, verification identity, scan date, and result in the runbook; do not record credentials or provider content.

- [ ] **Step 5: Verify the toolchain and repository**

Run the command from Step 1 again, then run `nix develop --command just validate`.

Expected: all five tool paths print and repository validation passes.

- [ ] **Step 6: Commit**

```bash
git add flake.nix apps/base/litellm/image-ref.txt \
  docs/runbooks/litellm-hermes-gateway.md
git commit -m "chore(litellm): pin Blablador gateway image"
```

### Task 2: Prove the Blablador Provider Contract

**Files:**
- Create: `apps/base/litellm/test_blablador_contract.py`
- Modify: `justfile`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: immutable image reference from Task 1 and a mode-`0600` env file outside the Git worktree containing only runtime credentials, including `BLABLADOR_API_KEY`.
- Produces: `just litellm-provider-contract ENV_FILE`, verified model string `openai/alias-code`, and documented `COMMON_CHAT_PARAMETERS` used by Task 3.

- [ ] **Step 1: Write the provider-contract tests**

Create `BlabladorContractTests` with:

```python
def test_chat_completion_schema_without_logging_content(self): ...
def test_stream_emits_at_least_two_chunks(self): ...
def test_deterministic_tool_call_shape(self): ...
```

Use model `alias-code`, API base `https://api.blablador.fz-juelich.de/v1`, and the image's OpenAI client. Assertions cover response object shape, at least two stream events, and exactly one requested function name plus JSON-object arguments. Failure messages name only status/schema conditions, never prompts, responses, headers, or key values.

- [ ] **Step 2: Add the protected opt-in recipe**

Add `just litellm-provider-contract ENV_FILE`. Before Podman starts, it must assert:

- `realpath ENV_FILE` is outside `git rev-parse --show-toplevel`;
- `stat -c %a ENV_FILE` equals `600`;
- the file declares `BLABLADOR_API_KEY` without printing its value.

Run the exact image from `image-ref.txt`, pass only `--env-file ENV_FILE`, mount `apps/base/litellm` read-only at `/work`, override the entrypoint to Python, and run only `test_blablador_contract.py`. Do not add this networked recipe to `just validate`.

- [ ] **Step 3: Verify unsafe credential sources fail closed**

Using throwaway files outside the repository, test mode `0644`, missing variable, and a path under the worktree.

Expected: each fails before image startup and output contains no values.

- [ ] **Step 4: Run the real provider contract**

Run:

```bash
nix develop --command just litellm-provider-contract /home/ingo/ansible/apikey.env
```

Expected: all three tests pass. If any fails, stop and revisit the selected model; do not create manifests.

- [ ] **Step 5: Record the request contract**

Document only test date, model, status, latency ranges, tool-call/stream compatibility, and the exact non-secret request parameter names exercised successfully. Name that set `COMMON_CHAT_PARAMETERS`; exclude `model` and `messages`, which Task 3 handles separately.

- [ ] **Step 6: Verify and commit**

Run `nix develop --command just validate` and `git diff --check`, then:

```bash
git add justfile apps/base/litellm/test_blablador_contract.py \
  docs/runbooks/litellm-hermes-gateway.md
git commit -m "test(litellm): verify Blablador provider contract"
```

### Task 3: Implement the Request Policy Test First

**Files:**
- Create: `apps/base/litellm/request_policy_core.py`
- Create: `apps/base/litellm/request_policy.py`
- Create: `apps/base/litellm/test_request_policy.py`
- Modify: `justfile`

**Interfaces:**
- Consumes: `COMMON_CHAT_PARAMETERS` from Task 2 and the normalized snapshot contract in LiteLLM `v1.104.0`.
- Produces: `PolicyViolation`, `validate_proxy_request(data: Mapping[str, object]) -> None`, `HermesRequestPolicy.async_pre_call_hook(...)`, and `hermes_request_policy`.

- [ ] **Step 1: Write failing dependency-free policy tests**

Create tests named:

```python
def test_accepts_exact_model_messages_and_common_parameters(self): ...
def test_rejects_other_model_or_missing_messages(self): ...
def test_rejects_unknown_provider_parameter(self): ...
def test_rejects_extra_body_and_routing_retry_drop_timeout_controls(self): ...
def test_rejects_x_litellm_control_header_case_insensitively(self): ...
def test_missing_or_malformed_proxy_snapshot_fails_closed(self): ...
def test_versioned_proxy_injected_fields_are_ignored_without_mutation(self): ...
```

Use `hermes-blablador`. Accepted data must remain equal to its deep copy; rejected messages name keys only.

- [ ] **Step 2: Run the tests and observe the import failure**

Run `python3 -m unittest apps/base/litellm/test_request_policy.py -v`.

Expected: import failure because `request_policy_core.py` is absent.

- [ ] **Step 3: Implement the dependency-free validator**

Define immutable sets for Task 2's common parameters, forbidden LiteLLM controls, and exact `v1.104.0` proxy-injected fields. Require `proxy_server_request.body.model == "hermes-blablador"`, list-valued `messages`, and no unknown provider-directed field or `x-litellm-*` control header. Do not mutate or log data.

- [ ] **Step 4: Implement the LiteLLM adapter**

Subclass `litellm.integrations.custom_logger.CustomLogger`, set `enforces_request_content = True`, and implement the exact four-argument `async_pre_call_hook`. Translate `PolicyViolation` to `fastapi.HTTPException(status_code=400, detail=...)`; otherwise return the original data. Export one `hermes_request_policy` instance.

- [ ] **Step 5: Add the fast tests to `just test` and verify green**

Run the policy test directly, then `nix develop --command just validate`.

- [ ] **Step 6: Commit**

```bash
git add justfile apps/base/litellm/request_policy_core.py \
  apps/base/litellm/request_policy.py apps/base/litellm/test_request_policy.py
git commit -m "feat(litellm): enforce Blablador request contract"
```

### Task 4: Pin LiteLLM Proxy and Single-Upstream Contracts

**Files:**
- Create: `apps/base/litellm/test_litellm_contract.py`
- Modify: `justfile`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: image reference, callback, and policy constants from Tasks 1-3.
- Produces: network-isolated `just litellm-contract` as the image-upgrade gate.

- [ ] **Step 1: Write failing exact-image contract tests**

Use `unittest`, FastAPI `TestClient`, the LiteLLM proxy, and loopback HTTP stubs. Add:

```python
def test_callback_loads_from_config_directory_and_returns_http_400(): ...
def test_proxy_snapshot_matches_pinned_injected_fields(): ...
def test_stripped_control_fields_are_ineffective(): ...
def test_success_calls_blablador_once(): ...
def test_400_401_429_and_5xx_each_call_blablador_once(): ...
def test_upstream_http_status_class_is_preserved(): ...
def test_stream_does_not_retry_after_first_chunk(): ...
```

The stub records only attempt count and stable deployment ID. It never stores message content.

- [ ] **Step 2: Add the isolated container recipe and observe failure**

Add `just litellm-contract` using the exact image from `image-ref.txt`, `--network=none`, a read-only `/work` mount, Python entrypoint, and only `test_litellm_contract.py`.

Expected before completing the harness: the first unimplemented assertion fails.

- [ ] **Step 3: Complete the loopback stubs and assertions**

Return controlled OpenAI-compatible success, 400, 401, 429, 500, and a stream that emits one chunk before failing. Require one attempt for every case and no retry after emitted output.

- [ ] **Step 4: Verify and document the pinned contract**

Run `nix develop --command just litellm-contract` and require all tests pass without external networking. Document that any image upgrade is blocked by a changed snapshot, strip-list, callback load, attempt count, or status-class result.

- [ ] **Step 5: Commit**

```bash
git add justfile apps/base/litellm/test_litellm_contract.py \
  docs/runbooks/litellm-hermes-gateway.md
git commit -m "test(litellm): pin Blablador proxy contracts"
```

### Task 5: Build the Stateless Runtime and Secret Boundary

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
- Consumes: image/model inputs and callback files from Tasks 1-4.
- Produces: `Deployment/litellm`, `Service/litellm`, `Secret/litellm`, and rendered-manifest checks.

- [ ] **Step 1: Write the failing manifest checker**

Create a Bash script with `set -euo pipefail` that renders `apps/base/litellm` and requires:

- one Deployment, one replica, `Recreate`, sync wave `0`, one worker, and image equal to `image-ref.txt`;
- secret revision annotation and `automountServiceAccountToken: false`;
- UID/GID `65534`, `RuntimeDefault`, no privilege escalation, dropped `ALL`, and read-only root;
- requests `250m`/`512Mi`, limits `1`/`1Gi`;
- bounded mounts `/tmp` 64Mi, `/app/.cache` 128Mi, `/app/migrations` 64Mi;
- no Prisma path overrides, PVC, DB, Redis, HPA, PDB, ServiceMonitor, UI, sidecar, or second deployment;
- one model `hermes-blablador`, one deployment ID, `openai/alias-code`, Blablador API base, and `num_retries: 0`;
- one ClusterIP Service on port 4000;
- Secret wave `-1` and exactly `BLABLADOR_API_KEY`, `LITELLM_MASTER_KEY`.

Run it and require failure because runtime resources are absent.

- [ ] **Step 2: Create namespace and LiteLLM config**

Set restricted Pod Security labels on namespace `litellm`. Configure exactly one `hermes-blablador` deployment with ID `hermes-blablador`, `model: openai/alias-code`, Blablador API base, and `api_key: os.environ/BLABLADOR_API_KEY`. Set `num_retries: 0`; do not configure fallback or alternative deployments.

Register `request_policy.hermes_request_policy`, set `drop_params: false`, `turn_off_message_logging: true`, local cost map, debug off, four in flight, four queued, and one-second queue timeout.

- [ ] **Step 3: Create Deployment and Service**

Mount config and both policy modules read-only from one ConfigMap. Pass `--config /app/config/config.yaml --port 4000`; set one worker, production mode, disabled UI/docs/OpenAPI, local cost map, cache and migration paths. Use readiness `/health/readiness` and liveness `/health/liveliness` on named port `http`.

Reference both Secret keys individually and create the bounded writable mounts. Use the image from `image-ref.txt` verbatim in `workload.yaml`.

- [ ] **Step 4: Create the encrypted two-key Secret**

Source the mode-`0600` provider env file outside the repository, generate the master key as `sk-` plus 64 lowercase hex characters, and feed a two-key YAML document to `sops --encrypt --input-type yaml --output-type yaml /dev/stdin`. The plaintext may exist only in protected shell variables and the pipe, never in argv, a repository file, output, or history. Set Secret sync wave `-1`.

Run `nix develop --command just secrets-check` and require encrypted SOPS metadata.

- [ ] **Step 5: Wire Kustomize and validation**

Generate one ConfigMap from `config.yaml`, `request_policy.py`, and `request_policy_core.py`; include the KSOPS generator and runtime resources. Add `scripts/ci/check-litellm.sh` to `just test` after rendering.

- [ ] **Step 6: Verify runtime manifests**

Run the manifest checker, `nix develop --command just litellm-contract`, `nix develop --command just validate`, and `git diff --check`.

- [ ] **Step 7: Commit**

```bash
git add justfile scripts/ci/check-litellm.sh apps/base/litellm
git commit -m "feat(litellm): add stateless Blablador gateway"
```

### Task 6: Enforce Ingress and Blablador Network Boundaries

**Files:**
- Create: `apps/base/litellm/ingress.yaml`
- Create: `apps/base/litellm/network-policy.yaml`
- Create: `apps/base/litellm/network_probe.py`
- Create: `apps/base/litellm/test_network_probe.py`
- Create: `apps/base/litellm/network-policy-probe.yaml`
- Create: `apps/overlays/main/litellm/kustomization.yaml`
- Modify: `apps/base/litellm/kustomization.yaml`
- Modify: `apps/overlays/main/cluster-config.yaml`
- Modify: `scripts/ci/check-litellm.sh`
- Modify: `justfile`

**Interfaces:**
- Consumes: Service port 4000 from Task 5 and rendered cluster selectors.
- Produces: TLS ingress `litellm.jit.services`, default-deny Cilium policy allowing only ingress-controller/DNS/Blablador TLS, `resolve(host: str) -> tuple[str, ...]`, `verified_tls(connect_host: str, server_hostname: str, timeout_seconds: float = 5.0) -> None`, `require_blocked(name: str, action: Callable[[], None]) -> None`, and a declarative PostSync egress probe.

- [ ] **Step 1: Extend the checker before network resources exist**

Require two `pathType: Exact` paths; body/rate/burst/no-delay/real-peer-key annotations; TLS secret `litellm-tls`; source and method checks in `nginx.org/location-snippets`; ingress only from rendered NGINX labels; DNS only to rendered kube-dns labels; and exactly one HTTPS egress name with matching `toFQDNs.matchName` and `toPorts.serverNames`. Also require one PostSync Job with the same Cilium policy label, a distinct non-Service component label, no Secret/envFrom/service-account token, the same pinned image, and the hardened server security context/resource bounds.

Expected: checker fails because the resources are absent.

- [ ] **Step 2: Discover selectors from rendered infrastructure and live read-only state**

Render `infrastructure/base/ingress-nginx` and inspect deployed kube-dns labels read-only. Record exact selectors in the runbook; do not guess them.

- [ ] **Step 3: Write failing network-probe unit tests**

Create tests named:

```python
def test_verified_tls_uses_default_context_and_expected_sni(self): ...
def test_require_blocked_fails_when_operation_returns(self): ...
def test_require_blocked_accepts_network_timeout_and_tls_errors(self): ...
def test_main_runs_allowed_and_all_blocked_cases_without_values(self): ...
```

Mock sockets, SSL, and DNS so the tests never use the network. Require the last test to cover allowed Blablador TLS plus unrelated DNS, `10.255.255.1`, `169.254.169.254`, and wrong SNI, while captured output contains only fixed case names and `PASS`/`FAIL`.

- [ ] **Step 4: Run the probe tests and observe the import failure**

Run `python3 -m unittest apps/base/litellm/test_network_probe.py -v`.

Expected: import failure because `network_probe.py` is absent.

- [ ] **Step 5: Create the exact-path Ingress**

Use exact `/v1/chat/completions` and `/v1/models`. Return 403 unless `$realip_remote_addr` equals `192.168.2.37`; return 405 unless method plus URI is exactly the allowed POST or GET pair. Set 1m body, 30r/m, burst 10, no delay, rate key `${realip_remote_addr}`, `letsencrypt-prod`, HTTPS redirect, host `litellm.jit.services`, and TLS secret `litellm-tls`.

- [ ] **Step 6: Create the CiliumNetworkPolicy**

Select the shared LiteLLM policy label used by server and probe. Allow TCP/4000 only from the ingress-controller selector. Allow TCP/UDP DNS only to kube-dns with L7 DNS for `api.blablador.fz-juelich.de`. Allow TCP/443 only through one exact FQDN rule paired with the same SNI. Add no OpenAI, Anthropic, world, CIDR, private, Link-Local, or metadata exception. Keep the Service selector narrower so it selects only the server component, never the probe Job.

- [ ] **Step 7: Implement the dependency-free probe core**

Implement the three exact interface functions above plus `main() -> int` using only the Python standard library and bounded socket/TLS timeouts. `main()` must require a successful certificate-valid TLS handshake to `api.blablador.fz-juelich.de:443`, then require failure for DNS lookup of `example.com`, TLS to `10.255.255.1`, TLS to `169.254.169.254`, and a connection to a currently resolved Blablador IP using SNI `example.com`. It prints only fixed case names and `PASS`/`FAIL`, never resolved addresses, exception strings, or response content.

- [ ] **Step 8: Run the probe tests and add them to local validation**

Run the direct unittest and require all four tests pass. Add the same network-free test module to `just test`, then run `nix develop --command just test`.

- [ ] **Step 9: Create the declarative PostSync Job**

Run it in a non-retrying ArgoCD `PostSync` Job using the pinned LiteLLM image, no Secret, no token, read-only root, bounded `/tmp`, server-equivalent security context, shared policy label, and distinct component label. Set hook deletion on success and a finite active deadline; any unexpected allowed path exits non-zero and fails the sync.

- [ ] **Step 10: Add overlay and hostname inventory**

Create the overlay with only the base resource and add `host_litellm: litellm.jit.services` to `cluster-config.yaml`.

- [ ] **Step 11: Verify and commit**

Run the checker, `nix develop --command just validate`, and `git diff --check`, then:

```bash
git add justfile apps/base/litellm apps/overlays/main/litellm \
  apps/overlays/main/cluster-config.yaml scripts/ci/check-litellm.sh
git commit -m "feat(litellm): restrict Blablador gateway network"
```

### Task 7: Merge Through GitOps and Run Live Acceptance

**Files:**
- Modify: `docs/runbooks/litellm-hermes-gateway.md`

**Interfaces:**
- Consumes: reviewed branch, Hermes still using Codex as primary, and read-only cluster access.
- Produces: healthy gateway plus ingress, policy, provider, and limit evidence.

- [ ] **Step 1: Run final pre-PR checks**

Run:

```bash
nix develop --command just validate
nix develop --command just litellm-contract
nix develop --command just litellm-provider-contract /home/ingo/ansible/apikey.env
git diff --check
```

Expected: every local, image, and live-provider gate passes without credential or content output.

- [ ] **Step 2: Review rendered secret metadata and immutable inputs**

Inspect only Secret metadata/key names. Confirm image tag plus digest, one upstream, no extra egress, and absence of HPA/PVC/DB/Redis/UI/management ingress.

- [ ] **Step 3: Create and merge through the normal PR path**

Push/create/merge only with explicit user authorization. Do not use mutating `kubectl`. Wait for ArgoCD, Deployment, Pod, Certificate, and Ingress to become healthy via read-only queries.

- [ ] **Step 4: Confirm Cilium L7 realization**

Require `enable-l7-proxy: "true"`, realized DNS proxy rules, only the Blablador FQDN, and matching SNI before provider traffic.

- [ ] **Step 5: Test API and source boundaries**

From `hermes01`, require valid-key success only for the allowed POST/GET pair and 401 for an invalid key. Require 404/405 for slash variants, child paths, wrong methods, `/`, health, docs, OpenAPI, UI, and management paths.

From another LAN host, require 403 normally and with forged `X-Forwarded-For: 192.168.2.37`. Confirm rendered NGINX uses `$realip_remote_addr`.

- [ ] **Step 6: Test egress and limits**

Verify the ArgoCD operation records a successful PostSync egress probe and Cilium realizes only the declared DNS/FQDN/SNI rules. Confirm current Blablador CNAME/IP rotation through read-only DNS and policy state; do not use `kubectl exec`. Require 413 above 1MiB, 429 beyond rate/burst, and 503 when in-flight plus queue is exhausted.

- [ ] **Step 7: Repeat live provider compatibility through the gateway**

Run ordinary, streaming, and deterministic tool-call requests against `hermes-blablador`. Require stable deployment ID `hermes-blablador` and no second upstream attempt. Record metadata only.

- [ ] **Step 8: Record and commit evidence**

Record date, statuses, latency ranges, ArgoCD revision, image digest, policy results, and deployment ID without keys/content. Run `nix develop --command just validate`, then commit only the runbook.

### Task 8: Prove Key Rotation and Close Gateway Readiness

**Files:**
- Modify: `apps/base/litellm/secret.sops.yaml`
- Modify: `apps/base/litellm/workload.yaml`
- Modify: `docs/runbooks/litellm-hermes-gateway.md`
- Modify: `docs/PRODUCTION-READINESS.md`

**Interfaces:**
- Consumes: accepted gateway while Hermes still uses Codex as primary.
- Produces: tested second master key for the dependent Ansible plan and closed gateway readiness.

- [ ] **Step 1: Rotate securely to revision `v2`**

Record the current commit hash as non-secret `ROTATION_BASE` in the runbook. Generate a second `sk-` plus 64-lowercase-hex key through protected stdin-only handling, replace only encrypted `LITELLM_MASTER_KEY`, and bump the pod annotation from `v1` to `v2`. Do not persist either plaintext key; the rejection test in Step 4 retrieves the old value from the encrypted file at `ROTATION_BASE` only when needed.

- [ ] **Step 2: Verify sync ordering and encrypted state**

Run the manifest checker and `nix develop --command just validate`. Require Secret wave `-1`, Deployment wave `0`, `Recreate`, revision `v2`, exactly two encrypted keys, and no plaintext diff.

- [ ] **Step 3: Commit and merge rotation through GitOps**

```bash
git add apps/base/litellm/secret.sops.yaml apps/base/litellm/workload.yaml
git commit -m "chore(litellm): rotate gateway master key"
```

Push/create/merge only with explicit authorization. Wait for Secret sync, old pod removal, and the new pod becoming Ready.

- [ ] **Step 4: Prove new-key acceptance and old-key rejection**

At test time, pipe the current encrypted Secret and `git show "${ROTATION_BASE}:apps/base/litellm/secret.sops.yaml"` separately through `sops --decrypt /dev/stdin`, select only `LITELLM_MASTER_KEY`, and capture each value in a protected shell variable. From `hermes01`, require `/v1/models` success with the current key and HTTP 401 with the base key. Pass Authorization through curl config stdin, not argv; print neither key nor header, then unset both variables.

- [ ] **Step 5: Close documentation and readiness**

Mark the gateway accepted and list only Hermes activation work in `PRODUCTION-READINESS.md`. Record rotation/rollback evidence and copy the runbook to `cfgmgmt01:/root/ansible/kellerio-docs/`.

- [ ] **Step 6: Final verification and commit**

Run `nix develop --command just validate`, `nix develop --command just litellm-contract`, and `git diff --check`, then:

```bash
git add docs/runbooks/litellm-hermes-gateway.md docs/PRODUCTION-READINESS.md
git commit -m "docs(litellm): record Blablador gateway acceptance"
```

The second master key is the only key handed securely to the dependent Hermes plan.
