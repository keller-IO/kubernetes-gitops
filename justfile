# Task runner for common GitOps workflows.
# Requires: kustomize, kubeconform, sops, age, yamllint (provided by the nix dev shell).

set shell := ["bash", "-cu"]

# List available recipes.
default:
    @just --list

# Render every ArgoCD source to catch build errors.
build:
    #!/usr/bin/env bash
    set -euo pipefail
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    bash scripts/ci/render-all.sh "$work/rendered"

# Lint YAML formatting.
lint:
    yamllint -s .
    actionlint .github/workflows/ci.yml

# Run application and CI guard regression tests.
test:
    #!/usr/bin/env bash
    set -euo pipefail
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/ci -p 'test_*.py'
    bash scripts/ci/check-talos-upgrade.sh
    python3 scripts/ci/test-check-schemas.py
    bash scripts/ci/test-render-all.sh
    bash scripts/ci/integration/test-guards.sh
    bash scripts/ci/integration/test-image-pull.sh
    bash scripts/ci/integration/test-prepare.sh
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s apps/base/nextcloud-yealink-phonebook -p 'test_*.py'
    PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=apps/base/litellm python3 -m unittest apps/base/litellm/test_request_policy.py
    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest apps/base/litellm/test_network_probe.py

# Encrypt a single secret in place.
encrypt FILE:
    sops --encrypt --in-place {{FILE}}

# Decrypt a single secret to stdout.
decrypt FILE:
    sops --decrypt {{FILE}}

# Verify real *.sops.yaml secrets are encrypted. Blueprint placeholders warn only.
secrets-check:
    bash scripts/ci/test-check-sops.sh
    ./scripts/ci/check-sops.sh

# Check repo safety invariants before CI or PR review.
guardrails:
    ./scripts/ci/guardrails.sh

# Validate Renovate configuration and extract dependencies locally without writes.
renovate-check:
    bash scripts/ci/check-renovate.sh

# Regenerate the tool-native agent configs (AGENTS.md, CLAUDE.md, .claude/,
# .opencode/, .codex/, .cursor/) from the .rulesync/ source of truth. Root
# AGENTS.md and CLAUDE.md are tracked bootstraps; other outputs are ignored.
agents-setup:
    rulesync generate

# Check agent config after setup; a fresh checkout must run agents-setup first.
agents-check:
    rulesync doctor --strict
    rulesync generate --check

# Render once and enforce schema, HPA, PVC and security contracts.
render-check:
    bash scripts/ci/render-check.sh

# Run the full static gate used by CI, without production credentials.
validate: agents-check lint secrets-check guardrails renovate-check test render-check

# Run both isolated integration scenarios (CI runs them on separate runners).
integration: integration-install integration-upgrade

# Fresh install of the candidate revision through ArgoCD.
integration-install:
    bash scripts/ci/integration/run.sh --mode install

# Upgrade the base revision to the candidate and verify persistent data.
integration-upgrade:
    bash scripts/ci/integration/run.sh --mode upgrade

# Run the opt-in Blablador provider contract against the pinned LiteLLM image.
litellm-provider-contract ENV_FILE:
    #!/usr/bin/env bash
    set -euo pipefail
    repo_root="$(realpath "$(git rev-parse --show-toplevel)")"
    env_file="$(realpath -- {{quote(ENV_FILE)}})"
    case "$env_file" in
      "$repo_root"|"$repo_root"/*)
        echo "ERROR: credential file must be outside the repository" >&2
        exit 1
        ;;
    esac
    if [[ "$(stat -c %a -- "$env_file")" != "600" ]]; then
      echo "ERROR: credential file mode must be 600" >&2
      exit 1
    fi
    declaration_count="$(grep -Ec '^BLABLADOR_API_KEY=' "$env_file" || :)"
    nonempty_count="$(grep -Ec '^BLABLADOR_API_KEY=.+$' "$env_file" || :)"
    if [[ "$declaration_count" != "1" || "$nonempty_count" != "1" ]]; then
      echo "ERROR: credential file must contain exactly one non-empty BLABLADOR_API_KEY assignment" >&2
      exit 1
    fi
    image_ref="$(<"$repo_root/apps/base/litellm/image-ref.txt")"
    repository_with_tag="${image_ref%@*}"
    policy_scope="${repository_with_tag%:*}@${image_ref##*@}"
    podman_config="$(mktemp -d)"
    podman_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    trap 'rm -rf "$podman_config"' EXIT
    mkdir -p "$podman_config/.config/containers"
    jq -n --arg scope "$policy_scope" \
      '{default: [{type: "reject"}], transports: {docker: {($scope): [{type: "insecureAcceptAnything"}]}}}' \
      >"$podman_config/.config/containers/policy.json"
    HOME="$podman_config" XDG_DATA_HOME="$podman_data_home" podman run --rm \
      --env-file "$env_file" \
      --volume "$repo_root/apps/base/litellm:/work:ro,Z" \
      --workdir /work \
      --entrypoint python \
      "$image_ref" \
      /work/test_blablador_contract.py

# Run the network-isolated LiteLLM proxy contract against the pinned image.
litellm-contract:
    #!/usr/bin/env bash
    set -euo pipefail
    repo_root="$(realpath "$(git rev-parse --show-toplevel)")"
    image_ref="$(<"$repo_root/apps/base/litellm/image-ref.txt")"
    repository_with_tag="${image_ref%@*}"
    policy_scope="${repository_with_tag%:*}@${image_ref##*@}"
    podman_config="$(mktemp -d)"
    podman_data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
    trap 'rm -rf "$podman_config"' EXIT
    mkdir -p "$podman_config/.config/containers"
    jq -n --arg scope "$policy_scope" \
      '{default: [{type: "reject"}], transports: {docker: {($scope): [{type: "insecureAcceptAnything"}]}}}' \
      >"$podman_config/.config/containers/policy.json"
    HOME="$podman_config" XDG_DATA_HOME="$podman_data_home" podman run --rm \
      --network none \
      --env LITELLM_DONT_SHOW_FEEDBACK_BOX=True \
      --env LITELLM_LOCAL_MODEL_COST_MAP=True \
      --volume "$repo_root/apps/base/litellm:/work:ro,Z" \
      --workdir /work \
      --entrypoint python \
      "$image_ref" \
      /work/test_litellm_contract.py

fmt:
    kustomize cfg fmt infrastructure apps clusters
