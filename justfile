# Task runner for common GitOps workflows.
# Requires: kustomize, kubeconform, sops, age, yamllint (provided by the nix dev shell).

set shell := ["bash", "-cu"]

# List available recipes.
default:
    @just --list

# Render every overlay with kustomize (helm inflation enabled) to catch build errors.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in apps/overlays/main/*/ infrastructure/base/*/; do
      [ -f "$dir/kustomization.yaml" ] || continue
      echo "== building $dir"
      kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$dir" >/dev/null
    done

# Lint YAML formatting.
lint:
    yamllint -s .

# Validate rendered manifests against Kubernetes + CRD schemas.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in apps/overlays/main/*/ infrastructure/base/*/; do
      [ -f "$dir/kustomization.yaml" ] || continue
      kustomize build --enable-helm --enable-alpha-plugins --enable-exec "$dir" | kubeconform -strict -ignore-missing-schemas -summary
    done

# Encrypt a single secret in place.
encrypt FILE:
    sops --encrypt --in-place {{FILE}}

# Decrypt a single secret to stdout.
decrypt FILE:
    sops --decrypt {{FILE}}

# Verify real *.sops.yaml secrets are encrypted. Blueprint placeholders warn only.
secrets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r f; do
      grep -q "sops:" "$f" && continue
      if grep -Eq "REPLACE_ME|CHANGE ME|PLACEHOLDER|placeholder|age1placeholder" "$f"; then
        echo "WARN placeholder secret not encrypted yet: $f"
      else
        echo "UNENCRYPTED: $f"
        fail=1
      fi
    done < <(find . -name '*.sops.yaml' -not -name '.sops.yaml')
    exit $fail

# Check repo safety invariants before CI or PR review.
guardrails:
    ./scripts/ci/guardrails.sh

# Run the full local gate used by CI.
validate: lint secrets-check guardrails build test

fmt:
    kustomize cfg fmt infrastructure apps clusters
