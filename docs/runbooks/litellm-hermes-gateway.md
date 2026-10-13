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

Reproduce the verification inside the repository dev shell:

```bash
VERIFIED_DIGEST="$(skopeo inspect \
  docker://ghcr.io/berriai/litellm-non_root:v1.104.0 | jq -r .Digest)"
VERIFIED_IMAGE_REF="ghcr.io/berriai/litellm-non_root:v1.104.0@${VERIFIED_DIGEST}"
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  "${VERIFIED_IMAGE_REF}"
trivy image --severity HIGH,CRITICAL --exit-code 1 "${VERIFIED_IMAGE_REF}"
```

Supply-chain records contain only image, signature, scan date, and result
metadata. Do not add credentials, prompts, responses, or provider content to
this runbook.
