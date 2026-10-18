# LiteLLM Hermes Gateway

## Immutable image baseline

Verified on 2026-10-13 before creating any gateway manifests.

- Image: `ghcr.io/berriai/litellm-non_root:v1.104.0`
- Manifest digest: `sha256:37066242e6b8327fdd627682a66a9ae2a599553b4d5a84c905c6d8b9eb35c01e`
- Immutable reference: `ghcr.io/berriai/litellm-non_root:v1.104.0@sha256:37066242e6b8327fdd627682a66a9ae2a599553b4d5a84c905c6d8b9eb35c01e`
- Verification identity and trust anchor: LiteLLM's long-lived Cosign public
  signing key, pinned to upstream source commit
  `0112e53046018d726492c814b3644b7d376029d0` at
  `https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub`.
- Signature result: pass. Cosign validated the claims, verified offline
  transparency-log inclusion, verified the signature against the pinned public
  key, and bound the signature to the manifest digest above.
- Vulnerability result: pass. Trivy 0.72.0 reported zero HIGH or CRITICAL
  vulnerabilities with exit code 0.

Reproduce the verification from the repository root in a non-interactive
dev-shell Bash:

```bash
nix develop --command bash -c '
set -euo pipefail
VERIFIED_IMAGE_REF="$(<apps/base/litellm/image-ref.txt)"
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  "${VERIFIED_IMAGE_REF}"
trivy image --severity HIGH,CRITICAL --exit-code 1 "${VERIFIED_IMAGE_REF}"
'
```

Supply-chain records contain only image, signature, scan date, and result
metadata. Do not add credentials, prompts, responses, or provider content to
this runbook.

## Blablador provider contract

Base contract verified on 2026-10-13 with model `openai/alias-code`.
Hermes' usage-stream request shape was reverified on 2026-10-17.

- Status: pass (3/3 contract tests).
- Latest observed request latency range: 1.589-33.000 seconds.
- Streaming compatibility: pass.
- Deterministic forced-tool compatibility: pass.
- `COMMON_CHAT_PARAMETERS`: `temperature`, `max_tokens`, `stream`, `tools`,
  `tool_choice`, `stream_options`.
- Hermes usage-stream extension: pass. Blablador accepts exactly the exercised
  `stream_options: {include_usage: true}` shape; the gateway rejects other
  `stream_options` values.

The parameter set excludes `model` and `messages`; those are handled separately
by the gateway configuration. Contract evidence contains no credentials,
prompts, responses, headers, request identifiers, tool argument values, or
provider-generated content.

## Pinned LiteLLM proxy contract

Base contract verified on 2026-10-14 against the immutable image reference
above with the container network disabled. Hermes' exact `stream_options`
shape and the rejection of `reasoning_effort` were reverified on 2026-10-18.
The test process used only a loopback OpenAI-compatible stub.

- Status: pass (8/8 contract tests).
- Callback loading: pass from its config directory without relying on that
  directory being in the Python module search path; a rejected provider field
  returned HTTP 400 before any upstream attempt.
- Stateless authentication: a missing key returned HTTP 401 and a supplied
  non-master key returned HTTP 400 with `no_db_connection`; the loopback stub
  recorded zero upstream attempts for both chat requests.
- Normalized `proxy_server_request` fields: `arrival_time`, `body`,
  `credential_fields`, `headers`, `method`, `url`.
- Normalized minimal body fields: `messages`, `metadata`, `model`.
- Proxy stripping: the exact `v1.104.0` root and metadata control-field sets are
  pinned and every field is proven ineffective before forwarding. This includes
  mock controls, callback registration/disabling, guardrail state, routing
  state, agentic-loop state, and injected identity/cache metadata.
- A mixed-case client `x-litellm-*` control header reaches the policy and is
  rejected with HTTP 400 before any upstream attempt.
- Upstream attempts: exactly one for success and each controlled 400, 401, 429,
  and 500 response.
- Status propagation: 4xx and 5xx classes preserved.
- Streaming: the known first upstream chunk reaches the client and no retry
  occurs when the stream then fails.
- Stable deployment ID observed on every upstream attempt:
  `hermes-blablador`.
- The streaming test includes Hermes' exact
  `stream_options: {include_usage: true}` request shape and still proves one
  upstream attempt after the first returned chunk.

Reproduce from the repository root:

```bash
nix develop --command just litellm-contract
```

`just litellm-contract` reads `apps/base/litellm/image-ref.txt`, starts that
exact image with `--network none`, and mounts the contract files read-only. An
image update is blocked if callback loading, normalized snapshot fields,
proxy-stripped controls, attempt counts, deployment identity, status classes,
or post-chunk streaming behavior changes.

## Network selector baseline

Discovered on 2026-10-15 from the rendered infrastructure and confirmed with
read-only queries against the running kellerIO cluster:

- NGINX Ingress Controller namespace: `ingress-nginx`
- NGINX pod labels: `app.kubernetes.io/instance=nginx-ingress` and
  `app.kubernetes.io/name=nginx-ingress`
- Cluster DNS namespace: `kube-system`
- Cluster DNS pod label: `k8s-app=kube-dns`
- Cilium image: `quay.io/cilium/cilium:v1.16.5` with its repository-pinned
  digest
- Cilium `enable-l7-proxy`: `true`

The CiliumNetworkPolicy renders these Kubernetes labels with Cilium's `k8s:`
source prefix. The server and PostSync probe share only
`network-policy.jit.land/identity=litellm` for policy selection. The Service
continues to select `app.kubernetes.io/name=litellm` plus
`app.kubernetes.io/component=server`, so it cannot route to the probe.

The explicit ClouDNS A record `litellm.jit.services -> 192.168.2.246` was created
on 2026-10-16 before merging the overlay. The ClouDNS API returned exactly one
active `litellm` A record with TTL 3600; `pns31` through `pns34` and the public
resolvers `1.1.1.1`, `8.8.8.8`, and `9.9.9.9` all returned the target address.
This is required because DNS-01 creates `_acme-challenge.litellm.jit.services`;
without the explicit application record that node makes `litellm.jit.services`
an empty non-terminal and suppresses the existing `*.jit.services` wildcard,
potentially caching NODATA for up to an hour. See
`docs/learnings/wildcard-dns01-empty-non-terminal.md`.

The PostSync probe's strongest negative control is a certificate-valid TLS
handshake to `1.1.1.1` with SNI `one.one.one.one`: it succeeds on an unrestricted
network and therefore fails the hook if broad public egress is available. The
private, metadata, unrelated-DNS, and wrong-SNI cases remain defense-in-depth
checks; their failures can also originate outside Cilium, so static exact-policy
validation and live Cilium policy evidence remain mandatory.

## Live GitOps acceptance before key rotation

Verified on 2026-10-17 while Hermes continued to use Codex as its primary
provider.

- Git revision: `daaa517af7e9277f0ede5e0be46121d0af0d5a17`.
- ArgoCD: `app-litellm` was `Synced` and `Healthy`; its operation succeeded and
  recorded the `litellm-network-policy-probe` PostSync hook as successful.
- Runtime: one Deployment replica was Ready and Available; the only server pod
  was Running and Ready with zero restarts. `Certificate/litellm-tls` was Ready.
- Image digest:
  `sha256:37066242e6b8327fdd627682a66a9ae2a599553b4d5a84c905c6d8b9eb35c01e`.
- Cilium: `enable-l7-proxy=true`; `CiliumNetworkPolicy/litellm` was Valid with
  exactly the declared DNS rule and Blablador TCP/443 FQDN plus matching SNI
  rule. Blablador resolved through `zam12059.zam.kfa-juelich.de` to
  `134.94.198.59` during acceptance.
- Source boundary: a non-Hermes LAN source received HTTP 403 both normally and
  with forged `X-Forwarded-For: 192.168.2.37`. The rendered source check uses
  `$realip_remote_addr`.
- API boundary from `hermes01`: the valid-key model and chat routes returned
  HTTP 200. Missing credentials returned 401. A supplied, well-formed but
  non-master key returned 400 with structural type `no_db_connection`. The
  exact-image stateless-auth contract independently proved zero provider
  attempts for both rejection paths using the chat route.
- Route boundary: disallowed methods returned 405; appended slashes, child
  paths, `/`, health, documentation, OpenAPI, UI, key, and management paths
  returned 404.
- Limits: a body larger than 1 MiB returned 413; the rate/burst test returned
  429 on request 12; the ninth concurrent authorized request returned 503 when
  four in-flight and four queued requests exhausted admission capacity. The
  ingress rate limiter was independently observed returning 429, distinguishing
  the admission 503 from rate limiting.
- Gateway provider compatibility: model discovery returned the sole deployment
  ID `hermes-blablador` in 0.040 seconds. Ordinary chat passed its response
  schema in 8.438 seconds and carried the same deployment ID in the LiteLLM
  response metadata. Streaming produced 34 valid chunks plus the terminal
  marker in 2.346 seconds. The deterministic forced-tool response passed its
  function-call and JSON-argument shape in 4.084 seconds.
- Retry boundary: the deployed configuration has no fallback and
  `num_retries: 0`; the exact-image proxy contract proves one upstream attempt
  for success and controlled errors, including failure after a first streaming
  chunk. No second upstream path exists in the accepted runtime configuration.

The live test output contained only status, latency, count, field-shape, and
deployment metadata. It contained no credentials, prompts, responses, request
identifiers, tool argument values, or provider-generated content. This
acceptance left only the Task 8 master-key rotation and old-key rejection proof
open for gateway readiness.

## Master-key rotation

- Rotation base: `0f6d50bf26269ab0abef258c1799359c899dc46a`

Verified on 2026-10-17 while Hermes continued to use Codex as its primary
provider.

- GitOps rotation commit: `449d917b36843aa3b5ed3ddf88946b76be97042a`.
- Merged ArgoCD revision: `2f4a67dbc0aa673c40e269f17b6a5f870a083ae1`.
- The Secret changed in sync wave `-1` before the `Recreate` Deployment in
  wave `0`. The old `v1` pod was removed, and exactly one replacement pod with
  secret revision `v2` became Ready. ArgoCD finished `Synced`, `Healthy`, and
  `Succeeded`.
- From `hermes01`, the current key returned HTTP 200 from `/v1/models` with
  exactly the deployment ID `hermes-blablador`. The key retrieved transiently
  from the encrypted Secret at the rotation base returned HTTP 400 with
  `error.type=no_db_connection`.
- Both Authorization headers were supplied through curl configuration on
  standard input. Neither plaintext key nor header was printed or persisted.
  The live test used only the models route and therefore generated no provider
  content. The pinned-image stateless-auth contract separately proves that a
  rejected chat request makes zero Blablador attempts.

The encrypted file at the rotation base is the rollback anchor for this first
rotation; no rollback was needed. A gateway rollback reverts the rotation
through GitOps, waits for the Secret and `v1` replacement pod, and then repeats
the current/base-key checks with their expected results reversed.

For every later production rotation, first switch Hermes through its managed
rollback path to Codex as the primary provider and verify that state. Rotate the
SOPS key and Hermes's Ansible Vault value only afterward, and restore Blablador
as primary only after the new key passes. Do not rely on Hermes classifying the
old key's HTTP 400 response as a fallback-triggering error.

## Hermes production acceptance

Verified on 2026-10-18 with the pinned Hermes Agent revision documented in the
central Ansible runbook. The final enabled Ansible state is commit `fe9d42d`.

- The effective route is `custom:litellm` with model `hermes-blablador`; Hermes
  reports the normalized runtime provider as `custom`. The gateway transport is
  Chat Completions, the app-level retry count is one attempt, auto-recovery is
  disabled, and the sole fallback is `openai-codex` with `gpt-5.6-sol`.
- Normal completion and streaming succeeded through Blablador. A separate
  read-only tool turn completed two terminal tool calls; all three API calls in
  that turn used `hermes-blablador` rather than Codex.
- A controlled rate probe produced 18 expected policy HTTP 400 responses before
  the limit and then 102 HTTP 429 responses. The immediately following Hermes
  turn completed through `openai-codex`; after the rate window expired, the next
  turn returned to `hermes-blablador` with one API call.
- Rollback commit `dd897a4` removed only `/etc/hermes/config.yaml` and
  `/etc/hermes/.env`. The effective primary reverted to
  `openai-codex`/`gpt-5.6-sol`, one bounded turn completed, and a second Ansible
  run reported `changed=0`, `failed=0`.
- Reactivation commit `fe9d42d` restored the managed files and passed the role
  contract, syntax check, check mode, deployment, and a second idempotent run.
  The final bounded turn reported `model=hermes-blablador`, `provider=custom`,
  one API call, `completed=true`, and `failed=false`. The following five-minute
  gateway error window was clean and the Deployment remained `1/1 Ready`.

Acceptance records contain only dates, commit IDs, status classes, counts,
provider/model transitions, and completion metadata. They exclude credentials,
headers, prompts, responses, request/session identifiers, and tool arguments.
