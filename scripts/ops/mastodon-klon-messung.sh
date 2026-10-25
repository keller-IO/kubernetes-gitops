#!/usr/bin/env bash
# Restore-Klon von mastodon-pg ausserhalb des Clusters: stellt das letzte
# Barman-Backup aus Garage wieder her und misst die db:migrate-Phasen eines
# neuen Mastodon-Images (Runbook docs/runbooks/mastodon-migration.md).
#
# Laeuft auf einem Wegwerf-Host in Potsdam im LAN von Garage, NICHT im Cluster:
# Der Klon im Cluster zog am 24.10.2026 Basis-Backup und WAL ueber VPN/WAN2,
# legte damit alle Dienste auf WAN2 lahm und belastete Ceph.
#
# Kein kubectl, kein Cluster-Zugriff. Der Klon archiviert nichts
# (archive_mode=off) und liest den Backup-Pfad nur.
#
# Voraussetzungen auf dem Host: Docker, Zugriff auf 192.168.23.21:3900 und
# ghcr.io, etwa 100 GB frei unter KLON_DIR, 8 GB RAM. In KLON_DIR liegen
# s3.env und mastodon.env (Erzeugung siehe Runbook).
#
# Nutzung: mastodon-klon-messung.sh restore|measure|all|cleanup
#   restore  Basis-Backup holen, WAL einspielen, bis der Klon promotet ist
#   measure  Vorab-Abfragen, REFRESH-Vergleich, Pre- und Post-Phase mit Zeiten
#   all      restore, dann measure
#   cleanup  Container, Netz, Daten und Env-Dateien loeschen (Logs bleiben)
set -euo pipefail

klon_dir="${KLON_DIR:-/srv/mastodon-klon}"
mastodon_image="${MASTODON_IMAGE:-ghcr.io/mastodon/mastodon:v4.7.3}"
# Wie apps/base/mastodon/database.yaml und cache.yaml; die Postgres-Major muss
# zum Backup passen (wird geprueft).
pg_image="${PG_IMAGE:-ghcr.io/cloudnative-pg/postgresql:16.15-202610190958-system-bookworm@sha256:34be1a40793eb0f1452200cb52facebdc6c4a2fb8ca040688788eda07b7529a0}"
valkey_image="${VALKEY_IMAGE:-valkey/valkey:9.2-alpine}"
# u22 hat 4 Kerne und traegt PBS und Garage; ungebremst stieg die Last beim
# Entpacken auf 16 (docs/learnings/restore-klon-ueber-vpn.md).
klon_cpus="${KLON_CPUS:-2}"
# Wie externalClusters/backup in apps/base/mastodon/database.yaml
s3_endpoint="http://192.168.23.21:3900"
s3_path="s3://backup-mastodon/cnpg/"
s3_server="mastodon-pg-r2"

net="mastodon-klon"
pg_ctr="mastodon-klon-pg"
redis_ctr="mastodon-klon-redis"
log_dir="$klon_dir/logs"

die() {
  printf 'FEHLER: %s\n' "$1" >&2
  exit 1
}

log() {
  printf '%s %s\n' "$(date -u +%FT%TZ)" "$1"
}

# Nur pgdata wird gemountet: KLON_DIR ist 0700 root, uid 26 kommt dort nicht hinein.
pgrun() {
  docker run --rm -i --user 26 --cpus "$klon_cpus" --network "$net" \
    --env-file "$klon_dir/s3.env" "$@"
}

psql_klon() {
  docker exec -i "$pg_ctr" psql -h /tmp -U postgres -d mastodon_production -X "$@"
}

# DB_HOST und Co. aus -e ueberschreiben die Werte aus mastodon.env (Cluster-
# ConfigMap). Der Container prueft das selbst, bevor er migriert. S3 aus, damit
# nichts den Medien-Bucket der Produktion anfasst.
mrun() {
  docker run --rm --network "$net" --memory 1536m \
    --env-file "$klon_dir/mastodon.env" \
    -e DB_HOST=pg -e DB_PORT=5432 -e DB_NAME=mastodon_production \
    -e DB_USER=mastodon -e DB_PASS=klon \
    -e REDIS_HOST=redis -e REDIS_PORT=6379 \
    -e S3_ENABLED=false -e ES_ENABLED=false \
    -e PGOPTIONS="-c lock_timeout=10s" \
    "$@"
}

ensure_network() {
  docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null
}

preflight() {
  command -v docker >/dev/null || die "docker fehlt"
  [[ -s "$klon_dir/s3.env" && -s "$klon_dir/mastodon.env" ]] \
    || die "$klon_dir/s3.env und mastodon.env fehlen (Runbook)"
  chmod 600 "$klon_dir/s3.env" "$klon_dir/mastodon.env"
  mkdir -p "$log_dir"
  ensure_network
}

restore() {
  [[ ! -e "$klon_dir/pgdata" ]] || die "$klon_dir/pgdata existiert schon, erst cleanup"
  local avail
  avail="$(df --output=avail -BG "$klon_dir" | tail -1 | tr -dc 0-9)"
  ((avail >= 80)) || die "nur ${avail} GB frei unter $klon_dir, 80 GB noetig"

  docker pull -q "$pg_image" >/dev/null

  local backup_id="${BACKUP_ID:-}"
  if [[ -z "$backup_id" ]]; then
    pgrun "$pg_image" barman-cloud-backup-list --endpoint-url "$s3_endpoint" --format json \
      "$s3_path" "$s3_server" >"$log_dir/backups.json"
    backup_id="$(pgrun "$pg_image" python3 -c '
import json, sys
b = [x for x in json.load(sys.stdin)["backups_list"] if x.get("status") == "DONE"]
print(max(b, key=lambda x: x["backup_id"])["backup_id"])' <"$log_dir/backups.json")"
  fi
  log "Basis-Backup $backup_id"

  install -d -o 26 -g 26 -m 700 "$klon_dir/pgdata"
  local t0=$SECONDS
  pgrun -v "$klon_dir/pgdata:/pgdata" "$pg_image" barman-cloud-restore \
    --endpoint-url "$s3_endpoint" "$s3_path" "$s3_server" "$backup_id" /pgdata
  log "Basis-Backup geladen in $((SECONDS - t0)) s"

  local image_major
  image_major="$(pgrun "$pg_image" postgres --version | sed -E 's/.* ([0-9]+)\..*/\1/')"
  [[ "$(cat "$klon_dir/pgdata/PG_VERSION")" == "$image_major" ]] \
    || die "Backup ist PG $(cat "$klon_dir/pgdata/PG_VERSION"), Image PG $image_major"

  # Die CNPG-Konfiguration verweist auf /controller (Zertifikate, Archivierung
  # per Manager). Beiseitelegen und eine eigene schreiben.
  mkdir -p "$klon_dir/cnpg-conf"
  local f
  for f in postgresql.conf postgresql.auto.conf custom.conf override.conf \
    pg_hba.conf pg_ident.conf standby.signal postmaster.pid; do
    [[ -e "$klon_dir/pgdata/$f" ]] && mv "$klon_dir/pgdata/$f" "$klon_dir/cnpg-conf/"
  done
  # Die Recovery verlangt mindestens die Werte der Produktion
  # (max_connections, max_worker_processes, ...; gelesen 24.10.2026).
  # shared_buffers wie die Produktion, damit der Vergleich passt.
  cat >"$klon_dir/pgdata/postgresql.conf" <<EOF
listen_addresses = '*'
unix_socket_directories = '/tmp'
max_connections = 100
max_worker_processes = 32
max_wal_senders = 10
max_locks_per_transaction = 64
max_prepared_transactions = 0
shared_buffers = 128MB
wal_compression = on
max_wal_size = 4GB
checkpoint_timeout = 15min
archive_mode = off
hot_standby = off
restore_command = 'barman-cloud-wal-restore --endpoint-url $s3_endpoint $s3_path $s3_server %f %p'
recovery_target_timeline = 'latest'
log_destination = 'stderr'
logging_collector = off
EOF
  # Nur im Docker-Netz erreichbar, kein Port nach aussen.
  printf 'local all all trust\nhost all all 0.0.0.0/0 trust\n' >"$klon_dir/pgdata/pg_hba.conf"
  : >"$klon_dir/pgdata/pg_ident.conf"
  mkdir -p "$klon_dir/pgdata/pg_wal"
  touch "$klon_dir/pgdata/recovery.signal"
  chown -R 26:26 "$klon_dir/pgdata"

  docker run -d --name "$pg_ctr" --network "$net" --network-alias pg \
    --user 26 --env-file "$klon_dir/s3.env" --cpus "$klon_cpus" --memory 3g --shm-size 1g \
    -v "$klon_dir/pgdata:/pgdata" "$pg_image" postgres -D /pgdata >/dev/null

  t0=$SECONDS
  log "WAL-Replay laeuft (docker logs -f $pg_ctr)"
  until [[ "$(psql_klon -Atc 'select pg_is_in_recovery()' 2>/dev/null)" == f ]]; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$pg_ctr")" == true ]] \
      || die "Postgres beendet, siehe docker logs $pg_ctr"
    sleep 30
  done
  log "Klon promotet nach $((SECONDS - t0)) s WAL-Replay"
  # Snowflake-ID: die oberen Bits sind Millisekunden, so reicht der Primaerindex.
  psql_klon -Atc "select 'Neuester Status: ' || to_timestamp((max(id) >> 16) / 1000.0) from statuses"
}

phase() {
  local name="$1"
  shift
  local t0=$SECONDS
  log "Phase $name startet"
  # shellcheck disable=SC2016 # $DB_HOST wertet der Container aus
  mrun "$@" "$mastodon_image" bash -c \
    '[ "$DB_HOST" = pg ] || { echo "DB_HOST=$DB_HOST, Abbruch"; exit 1; }; bundle exec rails db:migrate' \
    2>&1 | tee "$log_dir/$name.log"
  printf '%s: %d s\n' "$name" "$((SECONDS - t0))" | tee -a "$log_dir/summary.txt"
}

measure() {
  [[ "$(psql_klon -Atc 'select pg_is_in_recovery()' 2>/dev/null)" == f ]] \
    || die "Klon laeuft nicht oder ist noch in Recovery, erst restore"
  [[ "$(psql_klon -Atc "select count(*) from pg_roles where rolname = 'mastodon'")" == 1 ]] \
    || die "Rolle mastodon fehlt im Klon"
  docker pull -q "$mastodon_image" >/dev/null
  docker rm -f "$redis_ctr" >/dev/null 2>&1 || true
  docker run -d --name "$redis_ctr" --network "$net" --network-alias redis \
    "$valkey_image" >/dev/null

  : >"$log_dir/summary.txt"
  log "Vorab-Abfragen"
  psql_klon -A <<'SQL' | tee "$log_dir/vorab.txt"
select max(version) as schema_version from schema_migrations;
select count(*) as uri_duplikate from (select uri from accounts where uri <> '' group by uri having count(*) > 1) d;
select count(*) as fremd_ohne_uri from accounts where domain is not null and coalesce(uri, '') = '';
select count(*) as lokale_schluessel from accounts where domain is null and private_key is not null;
select (select count(*) from account_summaries) as summaries, (select count(*) from global_follow_recommendations) as recommendations;
select indexrelid::regclass as invalid_index from pg_index where not indisvalid;
SQL

  # Hardware-Vergleich: derselbe Refresh lief in der Produktion auf Ceph ueber
  # 14 min (docs/learnings/mastodon-migration-lock-stau.md).
  local t0=$SECONDS
  if psql_klon -c 'refresh materialized view concurrently account_summaries' >/dev/null; then
    printf 'refresh account_summaries (Produktion ~840 s): %d s\n' "$((SECONDS - t0))" \
      | tee -a "$log_dir/summary.txt"
  else
    log "REFRESH fehlgeschlagen, ohne Vergleichswert weiter"
  fi

  phase pre -e SKIP_POST_DEPLOYMENT_MIGRATIONS=true
  phase post

  log "Pruefungen danach"
  psql_klon -A <<'SQL' | tee "$log_dir/danach.txt"
select relname, relkind from pg_class where relname in ('account_summaries', 'global_follow_recommendations');
select count(*) as keypairs_main_key from keypairs where local_fragment = '#main-key';
select count(*) as private_key_in_accounts from accounts where private_key is not null;
select indexrelid::regclass as invalid_index from pg_index where not indisvalid;
SQL

  {
    echo "Langsamste Migrationen (s):"
    sed -nE 's/^== ([0-9]+ [A-Za-z0-9]+): migrated \(([0-9.]+)s\).*/\2 \1/p' \
      "$log_dir/pre.log" "$log_dir/post.log" | sort -rn | head -10
    echo
    echo "UpdateAccountSummariesToVersion3 (ab drop_view sperrt sie die Views):"
    sed -n '/UpdateAccountSummariesToVersion3: migrating/,/UpdateAccountSummariesToVersion3: migrated/p' \
      "$log_dir/pre.log"
  } | tee -a "$log_dir/summary.txt"
  log "Fertig, Ergebnis in $log_dir/summary.txt"
}

cleanup() {
  docker rm -f "$pg_ctr" "$redis_ctr" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf "${klon_dir:?}/pgdata" "${klon_dir:?}/cnpg-conf"
  rm -f "$klon_dir/s3.env" "$klon_dir/mastodon.env"
  log "Aufgeraeumt, Logs liegen in $log_dir"
}

case "${1:-}" in
  restore) preflight; restore ;;
  measure) preflight; measure ;;
  all) preflight; restore; measure ;;
  cleanup) cleanup ;;
  *) die "Nutzung: $0 restore|measure|all|cleanup" ;;
esac
