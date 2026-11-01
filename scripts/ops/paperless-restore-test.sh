#!/usr/bin/env bash
# Restore-Test des Paperless-Offsite-Exports (docs/runbooks/backup-restore.md,
# Abschnitt Paperless). Spielt export/current/ aus Garage in eine leere
# Paperless-Instanz mit eigenem Postgres ein und vergleicht sie mit der
# Produktion.
#
# Laeuft auf einem Wegwerf-Host in Potsdam im LAN von Garage (LXC auf u22),
# NICHT im Cluster: docs/learnings/restore-klon-ueber-vpn.md. Kein kubectl.
#
# Es laufen nur Management-Befehle und der Webserver, kein Celery-Worker und
# kein Scheduler: Die Restore-Instanz darf weder Mail abrufen noch Workflows
# ausfuehren.
#
# In RESTORE_DIR liegen vorab (Erzeugung siehe Runbook, Modus 600):
#   s3.env             RCLONE_CONFIG_G_* fuer einen Garage-Key NUR mit Leserecht
#   secrets.env        EXPORT_PASSPHRASE, PAPERLESS_SECRET_KEY
#   prod-checksums.txt id|checksum|archive_checksum|im Papierkorb (t/f)|added (Epoch)
#                      der Produktion (psql -At)
#
# Nutzung: paperless-restore-test.sh fetch|import|check|web|all|cleanup
#   fetch    export/current/ nach RESTORE_DIR/export laden
#   import   Postgres und Valkey starten, migrieren, document_importer
#   check    Sanity-Checker, Bestand und Checksummen gegen die Produktion
#   web      granian starten, Login, API, Download und Suche per HTTP pruefen
#   all      alles der Reihe nach
#   cleanup  Container, Netz, Daten und Env-Dateien loeschen (Logs bleiben)
set -euo pipefail

restore_dir="${RESTORE_DIR:-/srv/restore}"
# Muss die Version des Exports sein, also die von apps/base/paperless-ngx/values.yaml.
paperless_image="${PAPERLESS_IMAGE:-ghcr.io/paperless-ngx/paperless-ngx:2.20.15}"
pg_image="${PG_IMAGE:-postgres:17}"
valkey_image="${VALKEY_IMAGE:-valkey/valkey:9.2-alpine}"
net=paperless-restore
db_ctr=paperless-restore-db
redis_ctr=paperless-restore-redis
web_ctr=paperless-restore-web
# Nur im Restore: Testbenutzer fuer die API-Pruefung.
test_user=restoretest
test_pass="restoretest-$(hostname)"

cd "$restore_dir"

pl_env=(
  -e HOME=/tmp -e PAPERLESS_DBENGINE=postgresql -e PAPERLESS_DBHOST="$db_ctr"
  -e PAPERLESS_DBNAME=paperless -e PAPERLESS_DBUSER=paperless -e PAPERLESS_DBPASS=restore
  -e PAPERLESS_REDIS="redis://${redis_ctr}:6379" -e PAPERLESS_TIME_ZONE=Europe/Berlin
  -e PAPERLESS_URL=http://localhost:8000 -e PAPERLESS_SECRET_KEY
)
pl_vols=(
  -v "$restore_dir/data:/usr/src/paperless/data" -v "$restore_dir/media:/usr/src/paperless/media"
  -v "$restore_dir/consume:/usr/src/paperless/consume"
)

load_secrets() {
  set -a
  # shellcheck disable=SC1091
  . ./secrets.env
  set +a
  : "${EXPORT_PASSPHRASE:?fehlt in secrets.env}" "${PAPERLESS_SECRET_KEY:?fehlt in secrets.env}"
}

pl() {
  docker run --rm --network "$net" --user 1000:1000 -w /usr/src/paperless/src --entrypoint python3 \
    "${pl_env[@]}" "${pl_vols[@]}" -v "$restore_dir/export:/export:ro" \
    -v "$restore_dir/prod-checksums.txt:/prod-checksums.txt:ro" -e EXPORT_PASSPHRASE \
    -e TEST_USER="$test_user" -e TEST_PASS="$test_pass" \
    "$paperless_image" manage.py "$@"
}

fetch() {
  set -a
  # shellcheck disable=SC1091
  . ./s3.env
  set +a
  local start
  start=$(date +%s)
  rclone copy g:backup-paperless/export/current "$restore_dir/export" --checksum --transfers 8 --stats-one-line --stats 0
  echo "fetch: $(find export -type f | wc -l) Dateien, $(du -sh export | cut -f1), $(( $(date +%s) - start )) s"
  if echo probe | rclone rcat g:backup-paperless/restore-schreibtest.txt 2>/dev/null; then
    echo "WARNUNG: der Key darf schreiben, fuer den Test einen Key nur mit Leserecht nehmen" >&2
    exit 1
  fi
}

import() {
  load_secrets
  install -d -o 1000 -g 1000 data media consume
  chown -R 1000:1000 export
  docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net" >/dev/null
  docker rm -f "$db_ctr" "$redis_ctr" >/dev/null 2>&1 || true
  docker run -d --name "$db_ctr" --network "$net" -e POSTGRES_USER=paperless \
    -e POSTGRES_PASSWORD=restore -e POSTGRES_DB=paperless "$pg_image" >/dev/null
  docker run -d --name "$redis_ctr" --network "$net" "$valkey_image" >/dev/null
  until docker exec "$db_ctr" pg_isready -U paperless -q; do sleep 1; done
  sleep 2
  local start
  start=$(date +%s)
  pl migrate -v0
  pl document_importer /export --no-progress-bar --passphrase "$EXPORT_PASSPHRASE"
  echo "import: $(( $(date +%s) - start )) s inklusive Migration"
}

check() {
  load_secrets
  local out
  # Exit-Status des Pruefers getrennt von der Suche: ein abgebrochener Pruefer
  # besteht den Test nicht.
  out=$(pl document_sanity_checker --no-progress-bar 2>&1) || { printf '%s\n' "$out" >&2; echo "Sanity-Checker gescheitert" >&2; exit 1; }
  grep -E 'ERROR|WARNING|issue|OCR' <<<"$out" || echo "Sanity-Checker ohne Befund"
  pl shell -c '
import hashlib, os
from django.contrib.auth.models import User
from documents.models import Document, Tag, Workflow
docs = Document.objects.all()
print("Bestand: docs", docs.count(), "users", User.objects.count(), "tags", Tag.objects.count(), "workflows", Workflow.objects.count())
# Stand des Exports: rclone uebernimmt die mtime von manifest.json aus dem Bucket.
export_zeit = os.path.getmtime("/export/manifest.json")
prod, papierkorb, neuer = {}, [], []
for line in open("/prod-checksums.txt"):
    i, c, a, geloescht, added = line.rstrip("\n").split("|")
    if geloescht == "t":
        papierkorb.append(int(i))
    elif int(added) > export_zeit:
        neuer.append(int(i))
    else:
        prod[int(i)] = (c, a)
restore_ids = set(docs.values_list("id", flat=True))
print("Papierkorb der Produktion (nicht exportiert):", papierkorb)
print("nach dem Export hinzugekommen (nicht geprueft):", neuer)
fehlend = sorted(set(prod) - restore_ids)
print("in Produktion, nicht im Restore:", fehlend)
# Nach dem Export endgueltig geloeschte oder in den Papierkorb gelegte Dokumente.
print("im Restore, nicht in Produktion:", sorted(restore_ids - set(prod) - set(papierkorb)))
abw_db = abw_orig = abw_arch = 0
for d in docs.filter(id__in=prod):
    c, a = prod[d.id]
    abw_db += d.checksum != c or (d.archive_checksum or "") != a
    abw_orig += hashlib.md5(d.source_path.read_bytes()).hexdigest() != c
    abw_arch += d.has_archive_version and hashlib.md5(d.archive_path.read_bytes()).hexdigest() != a
print("abweichend: DB-Checksummen", abw_db, "Originale", abw_orig, "Archive", int(abw_arch))
if fehlend:
    raise SystemExit("Dokumente der Produktion fehlen im Restore")
if abw_db or abw_orig or abw_arch:
    raise SystemExit("Checksummen weichen von der Produktion ab")
if not User.objects.filter(username=os.environ["TEST_USER"]).exists():
    User.objects.create_superuser(os.environ["TEST_USER"], password=os.environ["TEST_PASS"])
'
}

web() {
  load_secrets
  docker rm -f "$web_ctr" >/dev/null 2>&1 || true
  docker run -d --name "$web_ctr" --network "$net" --user 1000:1000 -w /usr/src/paperless/src \
    -p 127.0.0.1:8000:8000 "${pl_env[@]}" "${pl_vols[@]}" --entrypoint granian "$paperless_image" \
    --interface asginl --host 0.0.0.0 --port 8000 paperless.asgi:application >/dev/null
  local url=http://127.0.0.1:8000 auth="${test_user}:${test_pass}" id code md5 prod fehler=0
  for _ in $(seq 1 60); do curl -sf -o /dev/null "$url/accounts/login/" && break; sleep 1; done
  # erwarte NAME SOLL IST: Abweichung ausgeben und am Ende scheitern.
  erwarte() {
    echo "$1: $3 (erwartet $2)"
    [ "$2" = "$3" ] || { echo "NICHT OK: $1" >&2; fehler=1; }
  }
  erwarte "Login-Seite HTTP" 200 "$(curl -s -o /dev/null -w '%{http_code}' "$url/accounts/login/")"
  erwarte "API ohne Login HTTP" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$url/api/documents/")"
  curl -sf -u "$auth" "$url/api/documents/?page_size=1&ordering=-added" | jq -c '{count, neuestes: .results[0] | {id, title}}'
  id=$(curl -sf -u "$auth" "$url/api/documents/?page_size=1&ordering=-added" | jq -e .results[0].id)
  curl -sf -u "$auth" -o /tmp/restore-doc "$url/api/documents/$id/download/?original=true"
  md5=$(md5sum < /tmp/restore-doc | cut -c1-32)
  prod=$(awk -F'|' -v i="$id" '$1==i{print $2}' prod-checksums.txt)
  [ -n "$prod" ] || { echo "NICHT OK: #$id fehlt in prod-checksums.txt" >&2; fehler=1; }
  erwarte "Download #$id md5" "$prod" "$md5"
  erwarte "Thumbnail HTTP" 200 "$(curl -s -u "$auth" -o /dev/null -w '%{http_code}' "$url/api/documents/$id/thumb/")"
  code=$(curl -sf -u "$auth" "$url/api/documents/?query=rechnung&page_size=1" | jq .count)
  echo "Volltextsuche 'rechnung': $code Treffer"
  [ "$code" -gt 0 ] || { echo "NICHT OK: Volltextsuche ohne Treffer" >&2; fehler=1; }
  [ "$fehler" -eq 0 ] || exit 1
  echo "Restore-Test BESTANDEN"
}

cleanup() {
  docker rm -f "$web_ctr" "$db_ctr" "$redis_ctr" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
  rm -rf data media consume export s3.env secrets.env prod-checksums.txt /tmp/restore-doc
}

case "${1:-}" in
  fetch | import | check | web | cleanup) "$1" ;;
  all) fetch; import; check; web ;;
  *) echo "Nutzung: $0 fetch|import|check|web|all|cleanup" >&2; exit 2 ;;
esac
