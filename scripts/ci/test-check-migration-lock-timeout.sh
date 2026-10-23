#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="$repo_root/scripts/ci/check-migration-lock-timeout.sh"
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

expect_fail() {
  local name="$1" output
  if output="$("$checker" "$fixture_dir/$name" 2>&1)"; then
    printf 'Expected %s to fail the lock_timeout check\n' "$name" >&2
    exit 1
  fi
  grep -Fq "MISSING LOCK TIMEOUT: $fixture_dir/$name/job.yaml" <<<"$output"
}

expect_pass() {
  local name="$1"
  if ! "$checker" "$fixture_dir/$name"; then
    printf 'Expected %s to pass the lock_timeout check\n' "$name" >&2
    exit 1
  fi
}

# The command form the Mastodon hooks used before the 2026-10-23 outage.
mkdir -p "$fixture_dir/flow-array"
cat >"$fixture_dir/flow-array/job.yaml" <<'EOF'
containers:
  - name: migrate
    command: ["bundle", "exec", "rails", "db:migrate"]
EOF
expect_fail flow-array

mkdir -p "$fixture_dir/block-list"
cat >"$fixture_dir/block-list/job.yaml" <<'EOF'
containers:
  - name: migrate
    command:
      - bundle
      - exec
      - rails
      - db:migrate
EOF
expect_fail block-list

mkdir -p "$fixture_dir/shell-string"
cat >"$fixture_dir/shell-string/job.yaml" <<'EOF'
containers:
  - name: migrate
    args: ["bundle exec rails db:migrate"]
EOF
expect_fail shell-string

# Two jobs, only one protected.
mkdir -p "$fixture_dir/one-of-two"
cat >"$fixture_dir/one-of-two/job.yaml" <<'EOF'
containers:
  - name: pre
    command: ["bundle", "exec", "rails", "db:migrate"]
    env:
      - name: PGOPTIONS
        value: "-c lock_timeout=10s"
---
containers:
  - name: post
    command: ["bundle", "exec", "rails", "db:migrate"]
EOF
expect_fail one-of-two

mkdir -p "$fixture_dir/protected"
cat >"$fixture_dir/protected/job.yaml" <<'EOF'
# db:migrate in a comment does not count.
containers:
  - name: migrate
    command: ["bundle", "exec", "rails", "db:migrate"]
    env:
      - name: PGOPTIONS
        value: "-c lock_timeout=10s"
  - name: status
    command: ["bundle", "exec", "rails", "db:migrate:status"]
EOF
expect_pass protected
