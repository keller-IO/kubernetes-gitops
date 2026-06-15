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
      kustomize build --enable-helm "$dir" >/dev/null
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
      kustomize build --enable-helm "$dir" | kubeconform -strict -ignore-missing-schemas -summary
    done

# Encrypt a single secret in place.
encrypt FILE:
    sops --encrypt --in-place {{FILE}}

# Decrypt a single secret to stdout.
decrypt FILE:
    sops --decrypt {{FILE}}

# Verify every *.sops.yaml is actually encrypted (no plaintext data leaking to git).
secrets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r f; do
      if ! grep -q "sops:" "$f"; then echo "UNENCRYPTED: $f"; fail=1; fi
    done < <(find . -name '*.sops.yaml')
    exit $fail

fmt:
    kustomize cfg fmt infrastructure apps clusters
