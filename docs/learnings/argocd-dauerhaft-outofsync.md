# ArgoCD: Apps stehen dauerhaft auf OutOfSync, obwohl nichts driftet

## Symptom

Ein großer Teil der Apps steht permanent auf `OutOfSync`, bei gleichzeitig
`Healthy`-Status — betroffen waren unter anderem `app-kimai`, `app-roundcube`,
`app-wordpress-1`, `app-wordpress-2`, `app-paperless-ngx`, `infra-ingress-nginx`,
`infra-monitoring` und `root`. Ein manueller Sync ändert nichts: die App springt
sofort wieder auf `OutOfSync`.

Weil `selfHeal: true` gesetzt ist, entsteht der falsche Eindruck, ArgoCD käme mit
dem Reconcile nicht hinterher oder jemand ändere ständig am Cluster vorbei.

## Ursache

Es driftet nichts. ArgoCD vergleicht das gerenderte Git-Manifest mit dem Live-Objekt
**inklusive der Felder, die der API-Server oder ein Operator per Defaulting
ergänzt**. Fehlt so ein Feld in Git, gilt das als Abweichung — und da der API-Server
es bei jedem Apply wieder setzt, ist der Zustand nicht auflösbar.

Nachgewiesene Fälle in diesem Repo:

| Ressource | In Git | Live zusätzlich | Quelle |
|---|---|---|---|
| `StatefulSet/*-valkey` | `volumeClaimTemplates[].spec` ohne `volumeMode` | `volumeMode: Filesystem` | API-Server-Default |
| `Service/nginx-ingress-controller` | `nodePort: null` | `nodePort: 32344` / `30241` | API-Server vergibt NodePorts |
| `MariaDB/*-mariadb` | schlanke CR | vom Operator gefüllte Felder | mariadb-operator |
| `ValidatingWebhookConfiguration` + `Secret` (monitoring) | ohne CA | `caBundle` injiziert | VictoriaMetrics-Operator |
| AppProtect-CRDs (`ap*.f5.com`) | Chart-Stand | großes Schema | Annotation-/Größenthematik |

Der Klassiker ist `volumeMode` in `volumeClaimTemplates`: ArgoCD normalisiert dieses
Feld bei StatefulSets nicht, deshalb sind **alle** Valkey-Caches betroffen. Das
erklärt die auffällige Häufung.

`root` ist ein Sonderfall: die App verwaltet die beiden ApplicationSets und
AppProjects, die ihrerseits laufend vom ApplicationSet-Controller angefasst werden.

## Diagnose

Zeigt, welche Ressourcen einer App abweichen — der erste Schritt, bevor man eine
echte Drift vermutet:

```sh
kubectl -n argocd get app <name> \
  -o jsonpath='{range .status.resources[?(@.status=="OutOfSync")]}{.kind}/{.name}{"\n"}{end}'
```

Anschließend Git-Soll gegen Live vergleichen:

```sh
kustomize build --enable-helm --enable-alpha-plugins --enable-exec apps/overlays/main/<app>/
kubectl -n <ns> get <kind> <name> -o yaml
```

Steht der Unterschied nur in Feldern, die man selbst nie gesetzt hat, ist es
Defaulting und **keine** Drift.

## Behebung

Zwei saubere Wege, je nach Fall:

1. **Feld in Git nachziehen**, wenn der Wert ohnehin fix ist — etwa `volumeMode:
   Filesystem` in die `volumeClaimTemplates` schreiben. Einfach und explizit.
2. **Diff ignorieren** über `ignoreDifferences` in der Application beziehungsweise
   im ApplicationSet-Template, wenn der Wert von außen kommt (`caBundle`,
   `nodePort`, Operator-Felder):

   ```yaml
   ignoreDifferences:
     - group: apps
       kind: StatefulSet
       jsonPointers: ["/spec/volumeClaimTemplates"]
   ```

Wichtig: Ein Patch direkt an einer generierten Application wird vom
ApplicationSet-Controller binnen einer Sekunde überschrieben. `ignoreDifferences`
gehört ins **Template** in `clusters/main/appset-apps.yaml` beziehungsweise
`appset-infrastructure.yaml`. Zum bloßen Pausieren einer einzelnen App siehe die
Reihenfolge mit `ignoreApplicationDifferences` (erst ApplicationSet, dann App).

## Konsequenz

Solange das nicht bereinigt ist, hat `OutOfSync` in diesem Cluster **keinen
Signalwert** — echte Drift geht im Rauschen unter. Das ist der eigentliche Schaden,
nicht der kosmetische Status.
