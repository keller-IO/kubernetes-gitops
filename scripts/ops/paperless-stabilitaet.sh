#!/usr/bin/env bash
# Stabilitaets-Gate vor dem Paperless-3.x-Upgrade (Runbook
# docs/runbooks/paperless-v3-upgrade.md, Abschnitt Stabilitaets-Gate).
#
# Nur lesend: kubectl get/logs und exec mit cat/grep/ls. Die Belege liegen auf
# der data-PVC: Paperless schreibt celery.log rotierend (20 x 1 MiB, etwa acht
# Wochen) nach /usr/src/paperless/data/log, sie ueberleben also Pod-Wechsel.
# Cgroup-Werte (memory.peak, memory.events) gelten nur seit dem letzten
# Container-Start.
#
# Gate bestanden, wenn kube-state-metrics mindestens 99 % der TAGE Tage
# abdeckt, celery.log* bis zum Beginn zurueckreicht und innerhalb von TAGE Tagen
#   - kein "Timed out waiting for UP message" in celery.log*,
#   - kein OOMKill und kein Container-Restart des laufenden Pods,
#   - kein oom_kill in memory.events.
#
# Nutzung: KUBECONFIG=... paperless-stabilitaet.sh [TAGE]   (Default 7)
# Exit 0 = Gate bestanden, 1 = nicht bestanden, 2 = Abfrage gescheitert.
set -euo pipefail

tage="${1:-7}"
ns=paperless-ngx
logdir=/usr/src/paperless/data/log
seit=$(date -u -d "-${tage} days" +%Y-%m-%d)
fehler=0

pod=$(kubectl -n "$ns" get pod -l app.kubernetes.io/name=paperless-ngx,app.kubernetes.io/instance=paperless \
  -o jsonpath='{.items[0].metadata.name}') || exit 2
[ -n "$pod" ] || { echo "kein Paperless-Pod gefunden" >&2; exit 2; }

echo "Pod $pod, Pruefzeitraum ab $seit (${tage} Tage)"
kubectl -n "$ns" get pod "$pod" -o jsonpath='{range .status.containerStatuses[*]}{"  Start "}{.state.running.startedAt}{", Restarts "}{.restartCount}{", letzter Abbruch "}{.lastState.terminated.reason}{" "}{.lastState.terminated.finishedAt}{"\n"}{end}'

# Laufender Pod direkt aus dem Pod-Status: letzter Abbruch im Pruefzeitraum.
ende=$(kubectl -n "$ns" get pod "$pod" \
  -o jsonpath='{.status.containerStatuses[?(@.name=="paperless-paperless-ngx")].lastState.terminated.finishedAt}') || exit 2
if [ -n "$ende" ] && [[ ! "${ende:0:10}" < "$seit" ]]; then
  echo "NICHT OK: laufender Container zuletzt abgebrochen am $ende"
  fehler=1
fi

# Restarts und OOMKills auch ersetzter Pods: aus VictoriaMetrics (kube-state-
# metrics), per GET ueber den API-Server-Proxy.
# vm QUERY [LEER]: LEER ist der Wert bei leerem Ergebnis. Ohne LEER ist ein
# leeres Ergebnis eine Messluecke und die Abfrage scheitert.
vm() {
  local q
  q=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/vmsingle-vm-k8s-stack-victoria-metrics-k8s-stack:8428/proxy/api/v1/query?query=${q}" \
    | python3 -c '
import json, sys
r = json.load(sys.stdin)["data"]["result"]
if r:
    print(round(float(r[0]["value"][1])))
elif len(sys.argv) > 1:
    print(sys.argv[1])
else:
    sys.exit("VictoriaMetrics: leeres Ergebnis, keine Messdaten")' ${2+"$2"}
}
sel='namespace="paperless-ngx",container="paperless-paperless-ngx"'
# Ohne lueckenlose kube-state-metrics-Daten belegen 0 Restarts nichts: Anteil
# der 5-Minuten-Buckets im Pruefzeitraum mit mindestens einem erfolgreichen
# Scrape. Feste Buckets statt scrape_interval(): Das gemessene Intervall waechst
# mit fehlenden Samples und wuerde Luecken ausgleichen.
ksm='up{job="kube-state-metrics"}'
abdeckung=$(vm "floor(count_over_time((max(max_over_time(${ksm}[5m])) == 1)[${tage}d:5m]) / (${tage} * 86400 / 300) * 100)") || exit 2
echo "  kube-state-metrics-Abdeckung ${tage} Tage: ${abdeckung} %"
if [ "$abdeckung" -lt 99 ]; then
  echo "kube-state-metrics deckt nur ${abdeckung} % des Pruefzeitraums ab (< 99 %)" >&2
  exit 2
fi
restarts=$(vm "sum(increase(kube_pod_container_status_restarts_total{${sel}}[${tage}d]))") || exit 2
# Unabhaengig davon, wie increase() eine neue Serie behandelt (z. B. Restart vor
# dem ersten Scrape, Zaehler beginnt bei 1): jeder Abbruch mit Zeitpunkt im
# Pruefzeitraum zaehlt.
fenster="> (time() - ${tage} * 86400)"
abbrueche=$(vm "count(max_over_time(kube_pod_container_status_last_terminated_timestamp{${sel}}[${tage}d]) ${fenster})" 0) || exit 2
# last_terminated_reason bleibt gesetzt, solange der Pod lebt; zaehlen nur
# Abbrueche, deren Zeitpunkt im Pruefzeitraum liegt.
ooms=$(vm "count(max_over_time(kube_pod_container_status_last_terminated_reason{${sel},reason=\"OOMKilled\"}[${tage}d]) > 0
  and on(namespace, pod, container)
  max_over_time(kube_pod_container_status_last_terminated_timestamp{${sel}}[${tage}d]) ${fenster})" 0) || exit 2
peak=$(vm "max(max_over_time(container_memory_working_set_bytes{${sel}}[${tage}d])) / 1048576") || exit 2
echo "  VictoriaMetrics ${tage} Tage: Restarts ${restarts}, Container mit Abbruch ${abbrueche}, davon OOMKill ${ooms}, Working-Set-Spitze ${peak} MiB"
if [ "$restarts" -gt 0 ] || [ "$abbrueche" -gt 0 ] || [ "$ooms" -gt 0 ]; then
  echo "NICHT OK: Container-Restarts oder OOMKills im Pruefzeitraum"
  fehler=1
fi

# Timeouts je Tag; nur Tage ab $seit zaehlen fuer das Gate.
echo "Celery 'Timed out waiting for UP message' je Tag (gesamte Log-Historie):"
timeouts=$(kubectl -n "$ns" exec "$pod" -c paperless-paperless-ngx -- \
  sh -c "cd $logdir && { grep -ah 'Timed out waiting for UP message' celery.log*; [ \$? -le 1 ]; }" \
  | cut -c2-11 | sort | uniq -c) || exit 2
if [ -n "$timeouts" ]; then
  printf '%s\n' "$timeouts" | sed 's/^/  /'
else
  echo "  keine"
fi
im_zeitraum=$(printf '%s\n' "$timeouts" | awk -v s="$seit" 'NF==2 && $2 >= s {n+=$1} END {print n+0}')
if [ "$im_zeitraum" -gt 0 ]; then
  echo "NICHT OK: $im_zeitraum Timeouts seit $seit"
  fehler=1
fi
aelteste=$(kubectl -n "$ns" exec "$pod" -c paperless-paperless-ngx -- \
  sh -c "ls -tr $logdir/celery.log* | head -1 | xargs head -c 30" | cut -c2-11) || exit 2
echo "  aelteste Log-Zeile: $aelteste"
# Fehlende oder unlesbare Logs ergeben kein Datum: kein Nachweis.
[[ "$aelteste" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { echo "kein Datum in $logdir/celery.log*" >&2; exit 2; }
if [[ "$aelteste" > "$seit" ]]; then
  echo "NICHT OK: Log-Historie reicht nicht bis $seit zurueck"
  fehler=1
fi

echo "Cgroup seit Container-Start:"
kubectl -n "$ns" exec "$pod" -c paperless-paperless-ngx -- sh -c '
  cd /sys/fs/cgroup
  awk "{printf \"  memory.current %.0f MiB\n\", \$1/1048576}" memory.current
  awk "{printf \"  memory.peak    %.0f MiB\n\", \$1/1048576}" memory.peak
  awk "{printf \"  memory.max     %s\n\", (\$1==\"max\") ? \$1 : sprintf(\"%.0f MiB\", \$1/1048576)}" memory.max
  sed "s/^/  events: /" memory.events' || exit 2
oom=$(kubectl -n "$ns" exec "$pod" -c paperless-paperless-ngx -- awk '$1=="oom_kill"{print $2}' /sys/fs/cgroup/memory.events) || exit 2
if [ "${oom:-0}" -gt 0 ]; then
  echo "NICHT OK: $oom oom_kill-Ereignisse seit Container-Start"
  fehler=1
fi

if [ "$fehler" -eq 0 ]; then
  echo "Gate BESTANDEN"
else
  echo "Gate NICHT bestanden"
fi
exit "$fehler"
