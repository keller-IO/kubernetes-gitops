# Collabora-HPA skalierte auf 55 Replicas und legte den Cluster lahm

## Symptom

Am 28.07.2026 war praktisch die gesamte Plattform-Infrastruktur defekt: **alle sieben
ArgoCD-Komponenten**, cert-manager, ceph-csi, cnpg und kube-state-metrics standen in
`CrashLoopBackOff`, 25 Pods hingen `Pending` mit `Insufficient memory`. Container
starteten mit `failed to start containerd task: cannot start a stopped process`.

Weil ArgoCD selbst betroffen war, heilte nichts von selbst — die GitOps-Reconciliation
stand still. `argocd app sync` scheiterte mit
`cannot find ready pod with selector: argocd-repo-server`.

Die Websites liefen weiter: Ingress-Controller und App-Pods waren nicht betroffen.

## Ursache

Das Deployment `collabora-collabora-online` stand bei **55 Replicas**. Bei 512Mi
Request pro Pod sind das rund **28 GB Memory-Requests** — mehr als die drei Worker
zusammen haben (je ~7,4 GB). Verschärft durch den gleichzeitigen Ausfall von
`kellerio-wrk2`, wodurch ein Drittel der Kapazität wegfiel.

Dahinter steckt eine Fehlkonfiguration mit zwei Stufen:

**1. Die HPA existierte ungewollt.** Das Chart `collabora-online` aktiviert
`autoscaling` per Default mit `maxReplicas: 100`. Dadurch wurde das explizite
`replicaCount: 1` aus unseren Values **vollständig ignoriert** — ein stiller
Widerspruch, den man den Values nicht ansieht.

**2. Das Skalierungsziel ist prinzipiell unerreichbar.** Die HPA skaliert auf
`memory` mit Ziel 50 % der Requests. Collabora belegt dauerhaft mehr als seinen
512Mi-Request — gemessen **104 %**. Dieser Wert ist aber *pro Pod*: zusätzliche
Replicas senken ihn nicht. Die HPA sieht also permanent eine Überschreitung, skaliert
hoch, misst erneut 104 %, skaliert weiter — monoton bis `maxReplicas`.

Das ist kein Tuning-Problem. Speicherbasiertes Autoscaling ist für eine Workload,
deren Speicherbedarf nicht mit der Replica-Zahl sinkt, grundsätzlich falsch.

## Die Falle: metrics-server ist keine Entwarnung

Der Cluster hatte zunächst **keinen** metrics-server. Die HPA stand deshalb auf
`ScalingActive=False, FailedGetResourceMetric` und war bei 55 Replicas **eingefroren**
— sie konnte weder hoch- noch **runter**skalieren.

Kurz darauf kam per PR #43 ein metrics-server dazu. Sobald der lieferte, skalierte die
HPA sofort **wieder hoch** (`memory: 104%/50%`), obwohl das Deployment zwischenzeitlich
manuell auf 1 gesetzt worden war.

Wer also aus „die HPA kann mangels Metriken nichts kaputtmachen" Sicherheit ableitet,
irrt: der fehlende metrics-server hat den Schaden nur eingefroren, nicht verhindert.

## Diagnose

Deployments finden, die deutlich über ihrem Git-Sollwert stehen:

```sh
kubectl get hpa --all-namespaces
kubectl get deploy --all-namespaces --no-headers | awk '$2!=$3'
```

Bei einer verdächtigen HPA immer die Conditions und die gemessene Utilization ansehen —
`ScalingActive=False` bedeutet eingefroren, nicht harmlos:

```sh
kubectl -n <ns> get hpa <name> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```

Steht dort ein Memory-Target und die Utilization dauerhaft über 100 %, ist die HPA in
einer Aufwärtsspirale.

## Behebung

Sofortmaßnahme (ArgoCD war tot, also griff kein selfHeal dagegen):

```sh
kubectl -n collabora delete hpa collabora-collabora-online
kubectl -n collabora scale deploy collabora-collabora-online --replicas=1
```

Danach fiel die Pod-Zahl von 150 auf 60, wrk3 ging von 99 % auf 73 % Memory-Requests,
und alle ArgoCD-Komponenten kamen von selbst hoch.

Dauerhaft in Git: `autoscaling.enabled: false` in
`apps/base/collabora/values.yaml`, damit `replicaCount` wieder greift.

## Konsequenz

- Bei jedem neuen Chart prüfen, ob es **ungefragt eine HPA mitbringt**. Ein gesetztes
  `replicaCount` ist kein Beweis, dass es auch wirkt — im Zweifel das gerenderte
  Manifest ansehen: `kustomize build ... | grep -A5 HorizontalPodAutoscaler`.
- `maxReplicas: 100` gehört nicht in einen Cluster mit drei 8-GB-Workern. Ein
  Chart-Default ist keine für die eigene Umgebung getroffene Entscheidung.
- Fehlen Requests/Limits im Verhältnis zum realen Verbrauch, ist jede
  Resource-basierte HPA unbrauchbar. Erst messen, dann Requests setzen, dann
  autoscalen — und dann auf CPU, nicht auf Memory.
