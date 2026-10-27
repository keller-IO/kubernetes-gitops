#!/usr/bin/env bash
# Regressionstest fuer paperless-stabilitaet.sh mit einem Fake-kubectl.
# Prueft die Entscheidungslogik (Exit 0/1/2), nicht die PromQL-Semantik.
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/paperless-stabilitaet.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/kubectl" <<'FAKE'
#!/usr/bin/env bash
# Antworten ueber FAKE_*-Variablen; leere Variable = leeres VM-Ergebnis.
args="$*"
vm() { [ -n "$1" ] && printf '{"data":{"result":[{"value":[0,"%s"]}]}}' "$1" || printf '{"data":{"result":[]}}'; }
case "$args" in
  *"get --raw"*)
    q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1].split("query=", 1)[1]))' "$args")
    case "$q" in
      *'up{job="kube-state-metrics"}'*) vm "${FAKE_COVERAGE-100}" ;;
      *restarts_total*) vm "${FAKE_RESTARTS-0}" ;;
      *OOMKilled*) vm "${FAKE_OOMS-}" ;;
      *last_terminated_timestamp*) vm "${FAKE_ABBRUECHE-}" ;;
      *working_set*) vm 1400 ;;
      *) echo "unerwartete Abfrage: $q" >&2; exit 1 ;;
    esac ;;
  *"get pod -l"*) echo paperless-paperless-ngx-test ;;
  *'lastState.terminated.finishedAt}'*) printf '%s' "${FAKE_ENDE-}" ;;
  *"get pod"*) echo "  Start 2026-10-27T05:46:21Z, Restarts 0" ;;
  *"Timed out"*) printf '%s' "${FAKE_TIMEOUTS-}" ;;
  *"ls -tr"*) printf '%s' "${FAKE_AELTESTE-[2000-01-01 00:00:01,000] [INFO]}" ;;
  *"-- awk"*) echo "${FAKE_OOMKILL-0}" ;;
  *"exec"*) echo "  memory.peak 2000 MiB" ;;
  *) echo "unerwarteter Aufruf: $args" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/kubectl"

fails=0
expect() {
  local want=$1 name=$2; shift 2
  local got=0
  env PATH="$work:$PATH" "$@" bash "$script" 7 > "$work/out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "ok   $name (Exit $got)"
  else
    echo "FAIL $name: Exit $got, erwartet $want"; sed 's/^/     /' "$work/out"
    fails=$((fails + 1))
  fi
}

expect 0 "sauberer Zeitraum"
expect 1 "Restart vor erstem Scrape: increase 0, Abbruch im Fenster" FAKE_RESTARTS=0 FAKE_ABBRUECHE=1
expect 1 "Restart laut increase" FAKE_RESTARTS=2 FAKE_ABBRUECHE=1
expect 1 "OOMKill im Fenster" FAKE_ABBRUECHE=1 FAKE_OOMS=1
# Zeitpunkte relativ zur Testausfuehrung, Pruefzeitraum 7 Tage
gestern=$(date -u -d '-1 day' +%Y-%m-%d)
vor_30_tagen=$(date -u -d '-30 days' +%Y-%m-%d)
expect 1 "laufender Container im Fenster abgebrochen" FAKE_ENDE="${gestern}T00:00:00Z"
expect 0 "laufender Container vor dem Fenster abgebrochen" FAKE_ENDE="${vor_30_tagen}T00:00:00Z"
expect 1 "Celery-Timeout im Fenster" FAKE_TIMEOUTS="[${gestern} 00:00:00,000] Timed out waiting for UP message"$'\n'
expect 0 "Celery-Timeout vor dem Fenster" FAKE_TIMEOUTS="[${vor_30_tagen} 00:00:00,000] Timed out waiting for UP message"$'\n' \
  FAKE_AELTESTE="[$(date -u -d '-40 days' +%Y-%m-%d) 00:00:00,000]"
expect 1 "Log-Historie zu kurz" FAKE_AELTESTE="[${gestern} 00:00:00,000]"
expect 1 "oom_kill in memory.events" FAKE_OOMKILL=1
expect 2 "keine Celery-Logs" FAKE_AELTESTE=
expect 2 "Restart-Abfrage ohne Messdaten" FAKE_RESTARTS=
expect 2 "kube-state-metrics-Abdeckung 98 %" FAKE_COVERAGE=98

# Die PromQL-Semantik prueft der Fake nicht; gegen VM verifiziert (Luecke
# 07.10.2026 14:45-15:30 UTC: 278/288 Buckets). Hier nur gegen Rueckfall auf
# das selbstausgleichende scrape_interval().
if grep -v '^[[:space:]]*#' "$script" | grep -q 'scrape_interval('; then
  echo "FAIL Abdeckung nutzt scrape_interval() statt fester Buckets"; fails=$((fails + 1))
else
  echo "ok   Abdeckung ueber feste 5-Minuten-Buckets"
fi

[ "$fails" -eq 0 ] || { echo "$fails Fall/Faelle fehlgeschlagen"; exit 1; }
