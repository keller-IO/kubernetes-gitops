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

Verified on 2026-10-13 with model `openai/alias-code`.

- Status: pass (3/3 contract tests).
- Observed request latency range: 0.998-7.121 seconds.
- Streaming compatibility: pass.
- Deterministic forced-tool compatibility: pass.
- `COMMON_CHAT_PARAMETERS`: `temperature`, `max_tokens`, `stream`, `tools`,
  `tool_choice`.

The parameter set excludes `model` and `messages`; those are handled separately
by the gateway configuration. Contract evidence contains no credentials,
prompts, responses, headers, request identifiers, tool argument values, or
provider-generated content.

## Pinned LiteLLM proxy contract

Verified on 2026-10-14 against the immutable image reference above with the
container network disabled. The test process used only a loopback
OpenAI-compatible stub.

- Status: pass (7/7 contract tests).
- Callback loading: pass from its config directory without relying on that
  directory being in the Python module search path; a rejected provider field
  returned HTTP 400 before any upstream attempt.
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
  non-master key returned 400 with structural type `no_db_connection` before
  provider routing, as specified for the stateless LiteLLM mode.
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
identifiers, tool argument values, or provider-generated content. Gateway
readiness remains open only for the Task 8 master-key rotation and old-key
rejection proof.
