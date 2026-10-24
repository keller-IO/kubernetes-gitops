# ArgoCD: Bootstrap-Reste von Dex und Notifications

## What went wrong

Beim Rollout von #366 (argo-cd 10.10.3 → 10.10.5) am 24.10.2026 trugen alle
ArgoCD-Workloads das Label `helm.sh/chart: argo-cd-10.10.5`, nur
`argocd-dex-server` und `argocd-notifications-controller` noch
`argo-cd-9.5.21`. Der Notifications-Controller lief weiter mit
`quay.io/argoproj/argocd:v3.4.3` neben den 3.5.5-Komponenten. Beide sind in
`infrastructure/base/argocd/values.yaml` abgeschaltet (`dex.enabled: false`,
`notifications.enabled: false`), `infra-argocd` stand trotzdem auf
`Synced/Healthy`.

```sh
kubectl -n argocd get deploy -o custom-columns='NAME:.metadata.name,CHART:.metadata.labels.helm\.sh/chart'
```

## Why it failed

- Der Erst-Bootstrap am 17.06.2026 lief ueber den OpenTofu-`helm_release`
  (`keller-IO/infrastructure`, `tofu/talos-cluster/envs/kellerIO/argocd.tf`,
  Chart `9.5.21`). Dessen Values setzen nur KSOPS und lassen Dex und
  Notifications auf dem Chart-Default, also an.
- Danach uebernahm `infra-argocd` die Ressourcen, die sein Render enthaelt.
  Dex- und Notifications-Objekte rendert es nicht, sie tragen deshalb keine
  `argocd.argoproj.io/tracking-id`. `prune: true` loescht nur Ressourcen mit
  Tracking-ID und hat sie nie angefasst.
- Dasselbe gilt feldweise: Server-Side-Apply entfernt nur Felder, die ArgoCD
  selbst besitzt. In `argocd-cmd-params-cm` gehoeren `server.dex.server` und
  `server.dex.server.strict.tls` allein dem Manager `terraform-provider-helm`
  und bleiben stehen, obwohl der aktuelle Render sie nicht mehr enthaelt.

Uebrig sind (nur Namespace `argocd`, Stand 24.10.2026):

| Art | Name |
|---|---|
| Deployment (mit ReplicaSets/Pods) | `argocd-dex-server`, `argocd-notifications-controller` |
| Service | `argocd-dex-server` |
| ServiceAccount, Role, RoleBinding | `argocd-dex-server`, `argocd-notifications-controller` |
| ClusterRole, ClusterRoleBinding | `argocd-notifications-controller` |
| ConfigMap / Secret | `argocd-notifications-cm` (nur `context`), `argocd-notifications-secret` (leer) |
| Felder in `argocd-cmd-params-cm` | `server.dex.server`, `server.dex.server.strict.tls` |

Dex wird nicht benutzt: Der Login laeuft ueber `oidc.config` in `argocd-cm`
direkt gegen Keycloak (`bgt`), `dex.config` ist nicht gesetzt. Notifications
hat weder Trigger noch Templates, und keine Application traegt
`notifications.argoproj.io/*`-Annotationen.

## The correct approach

Aufraeumen ist ein mutierender Eingriff ausserhalb von GitOps und laeuft
manuell mit Schreibzugriff. Die Helm-Release-Secrets
`sh.helm.release.v1.argocd.v*` **bleiben** stehen, weil der Tofu-State sie
braucht.

1. Pruefen, dass die Objekte weiterhin nicht von ArgoCD verwaltet werden. Die
   erste Abfrage muss `none` ausgeben, die zweite fuer beide Deployments
   `<none>`:

   ```sh
   kubectl -n argocd get application infra-argocd -o json \
     | jq -r '.status.resources[] | "\(.kind)/\(.name)"' | grep -E 'dex|notif' || echo none
   kubectl -n argocd get deploy argocd-dex-server argocd-notifications-controller \
     -o custom-columns='NAME:.metadata.name,TRACKING:.metadata.annotations.argocd\.argoproj\.io/tracking-id'
   ```

2. Loeschen (per Namen, nicht per Label-Selektor):

   ```sh
   kubectl -n argocd delete \
     deployment/argocd-dex-server deployment/argocd-notifications-controller \
     service/argocd-dex-server \
     serviceaccount/argocd-dex-server serviceaccount/argocd-notifications-controller \
     role/argocd-dex-server role/argocd-notifications-controller \
     rolebinding/argocd-dex-server rolebinding/argocd-notifications-controller \
     configmap/argocd-notifications-cm secret/argocd-notifications-secret
   kubectl delete clusterrolebinding/argocd-notifications-controller clusterrole/argocd-notifications-controller
   ```

3. Verwaiste Felder aus `argocd-cmd-params-cm` entfernen. `argocd-server` liest
   sie nur beim Start, und solange `dex.config` fehlt, nutzt er sie nicht. Ein
   Neustart ist deshalb nicht noetig:

   ```sh
   kubectl -n argocd patch configmap argocd-cmd-params-cm --type=json -p '[
     {"op":"remove","path":"/data/server.dex.server"},
     {"op":"remove","path":"/data/server.dex.server.strict.tls"}]'
   ```

4. Nachpruefen: Die Abfrage darf nichts mehr ausgeben, `infra-argocd` muss
   `Synced Healthy` melden, und der Keycloak-Login auf `argocd.jit.services`
   muss weiter funktionieren:

   ```sh
   kubectl get deploy,svc,sa,role,rolebinding,cm,secret -n argocd -o name | grep -E 'dex|notif'
   kubectl get clusterrole,clusterrolebinding -o name | grep -E 'argocd-(dex|notif)'
   kubectl -n argocd get application infra-argocd -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
   ```

## Prevention

- Ein unveraendertes `tofu apply` ist fuer den `helm_release` ein No-op. Jede
  Aenderung daran (Chart-Bump durch Renovate im Infrastruktur-Repo, neue Values)
  und jeder Neuaufbau fuehrt aber ein `helm upgrade`/`install` mit den heutigen
  Bootstrap-Werten aus und legt Dex und Notifications wieder an. Die
  Bootstrap-Values in `argocd.tf` muessen deshalb `dex.enabled = false` und
  `notifications.enabled = false` setzen, und `argocd_chart_version` muss der
  Minor-Version in `infrastructure/base/argocd/kustomization.yaml` folgen (heute
  `9.5.21` gegen `10.10.5`). Offen in `docs/PRODUCTION-READINESS.md`, Abschnitt 2.
- Allgemein: Wird eine Komponente, die der Tofu-Bootstrap angelegt hat, in den
  GitOps-Values abgeschaltet, raeumt ArgoCD sie nicht ab. Nach einer solchen
  Aenderung nach Objekten mit `meta.helm.sh/release-name`, aber ohne
  `argocd.argoproj.io/tracking-id` suchen:

  ```sh
  kubectl get deploy,ds,sts -A -o json | jq -r '.items[]
    | select(.metadata.annotations["meta.helm.sh/release-name"] != null
             and .metadata.annotations["argocd.argoproj.io/tracking-id"] == null)
    | "\(.metadata.namespace)/\(.kind)/\(.metadata.name)"'
  ```

- Kein CI-Guardrail: Das Muster entsteht aus Bootstrap-Werten in einem anderen
  Repository und aus dem Live-Zustand. Ein Source-Grep in diesem Repository
  kann es nicht erkennen.
