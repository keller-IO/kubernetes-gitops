#!/usr/bin/env bash
# Every Rails db:migrate job outside charts/ needs a lock_timeout in the same
# file (Mastodon outage 2026-10-23, docs/learnings/mastodon-migration-lock-stau.md).
# Matches db:migrate as a token, so shell strings ("rails db:migrate"), flow
# arrays (["rails", "db:migrate"]) and block lists (- db:migrate) all count;
# db:migrate:status and similar subtasks do not.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

fail=0
migrate_re='^[^#]*(^|[^[:alnum:]_:])db:migrate([^[:alnum:]_:]|$)'

if (($# > 0)); then
  search_roots=("$@")
else
  search_roots=(apps infrastructure clusters)
fi

while IFS= read -r f; do
  migrations="$(grep -cE "$migrate_re" "$f" || true)"
  timeouts="$(grep -cE '^[^#]*lock_timeout=' "$f" || true)"
  ((timeouts >= migrations)) && continue
  printf 'MISSING LOCK TIMEOUT: %s: %s db:migrate job(s) but only %s lock_timeout setting(s) — without one, a migration waiting for an exclusive lock queues every query on the table behind it. Set PGOPTIONS='\''-c lock_timeout=10s'\'' and retry on LockNotAvailable.\n' \
    "$f" "$migrations" "$timeouts" >&2
  fail=1
done < <(grep -RlE "$migrate_re" "${search_roots[@]}" \
  --include='*.yaml' --include='*.yml' --exclude-dir=charts 2>/dev/null || true)

exit "$fail"
