# NGINX Ingress Controller 5.x: ungültige Annotation verwirft den ganzen Ingress

## Symptom

Nach dem Bump des Charts `nginx-ingress` von 1.4.2 auf 2.6.4 (NIC 3.7.2 → 5.5.4,
PR #13) lieferte `radio.jit.services` plötzlich **404** statt des Icecast-Streams.
Der icecast-Pod lief (`1/1 Running`), der Service hatte einen gesunden Endpoint,
und ArgoCD meldete `app-icecast` als `Synced/Healthy`. Alle anderen 50 Hosts
funktionierten unverändert.

Im Controller-Log:

```
Event(Ingress icecast/icecast): type: 'Warning' reason: 'Rejected'
  annotations.nginx.org/proxy-buffering: Invalid value: "off": must be a boolean
```

## Ursache

Der Ingress trug `nginx.org/proxy-buffering: "off"`. NIC 3.x hat den Wert noch
geschluckt, NIC 5.x validiert Annotationen strikt: `proxy-buffering` erwartet ein
Boolean (`true`/`false`), nicht die NGINX-Schreibweise `on`/`off`.

Der entscheidende Punkt ist die **Fehlerbehandlung**: NIC ignoriert nicht etwa die
eine ungültige Annotation, sondern verwirft den **kompletten Ingress** (`Rejected`).
Damit existierte für den Host gar keine Server-Konfiguration mehr und nginx
beantwortete Anfragen aus dem Default-Server — daher 404 statt 502 oder 5xx.

Das macht die Sache tückisch:

- Kubernetes akzeptiert die Annotation weiter, sie ist nur ein String. Es gibt
  **keinen** Fehler beim `kubectl apply` oder beim ArgoCD-Sync.
- ArgoCD sieht die App als `Synced/Healthy` — der Ingress ist ja da, exakt wie in
  Git beschrieben. Der Health-Check kennt den NIC-internen Reject nicht.
- `kustomize build` und `kubeconform` rendern und validieren sauber; das Schema für
  `Ingress` sagt nichts über Annotationswerte.

Ein Manifest-Diff vor dem Merge (Rendern beider Chart-Versionen und Vergleich von
ConfigMap, Deployment, RBAC, CRDs) hat den Fehler folgerichtig **nicht** gefunden.
Sichtbar wurde er erst im Controller-Log und beim HTTP-Test gegen den LoadBalancer.

## Diagnose

Nach jedem NIC-Upgrade auf verworfene Ingresses prüfen:

```sh
kubectl -n ingress-nginx logs deploy/nginx-ingress-controller --since=10m \
  | grep "reason: 'Rejected'"
```

`cm-acme-http-solver-*`-Treffer sind normal (die ACME-Solver konkurrieren um Hosts,
die bereits von der echten App belegt sind) und können ignoriert werden.

Ergänzend die Hosts wirklich abfragen, statt sich auf den ArgoCD-Status zu verlassen:

```sh
kubectl get ingress -A --no-headers | grep -v cm-acme | awk '{print $4}' \
  | tr ',' '\n' | sort -u \
  | while read -r h; do
      printf '%-45s %s\n' "$h" \
        "$(curl -s -o /dev/null -w '%{http_code}' --resolve "$h:80:192.168.2.246" "http://$h/")"
    done
```

Während der docker15-Migration besitzen die bereits per DNS-01 lösbaren
`legacy-proxy`-Hosts Cluster-Zertifikate, aber noch keine HTTPS-Redirects. Namen
mit fehlender externer CNAME-Delegation bleiben HTTP-only und können bei einem
direkten HTTPS-Test weiterhin `unrecognized name` liefern. Deshalb Port 80 und
Port 443 getrennt gegen den erwarteten Migrationsstatus testen.

## Behebung

`nginx.org/proxy-buffering` auf `"false"` gesetzt
(`apps/base/icecast/workload.yaml`). `apps/base/legacy-proxy/ingress.yaml` nutzte
den korrekten Boolean-Wert bereits — der icecast-Ingress war der einzige Ausreißer.

## Konsequenz

- Bei Boolean-Annotationen (`proxy-buffering`, `ssl-redirect`, `redirect-to-https`,
  `proxy-buffering`, `hsts`) konsequent `"true"`/`"false"` schreiben, nie `on`/`off`.
- Ein NIC-Major-Upgrade ist mit Manifest-Diff allein **nicht** verifiziert. Nach dem
  Rollout gehören Controller-Log und ein HTTP-Sweep über alle Hosts dazu.
- Gleiche Klasse von Fallstrick beim selben Upgrade: `resolver-addresses` und
  `resolver-valid` sind seit NIC 5.x NGINX-Plus-only und werden mit
  `InvalidValue ... requires NGINX Plus` verworfen. Hier bleibt der Rest der
  ConfigMap wirksam ("updated with errors. Ignoring invalid values"), die Keys sind
  aber wirkungslos — sie wurden aus
  `infrastructure/base/ingress-nginx/values.yaml` entfernt.
