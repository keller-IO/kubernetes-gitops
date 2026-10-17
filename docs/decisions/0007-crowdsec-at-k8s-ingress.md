# ADR 0007 — CrowdSec am Kubernetes-Ingress (Direktweg Halbe)

- **Status:** Teilweise umgesetzt — Detection und Client-IP erledigt, Enforcement offen
- **Datum:** 2026-07-26 (Entwurf), nachgetragen 2026-10-17
- **Hinweis:** Der Entwurf entstand als „ADR 0003“, wurde aber nie eingereicht; die
  Nummer 0003 ist inzwischen vergeben. Der Text unten ist der Entwurf vom 26.07.2026,
  nur die DESY-Netze sind ohne CIDR genannt.

## Stand 2026-10-17

- **Detection:** umgesetzt seit 27.07.2026 (`infrastructure/base/crowdsec/`, siehe
  `docs/PRODUCTION-READINESS.md` Abschnitt 16) — Agent liest die Logs von
  nginx-ingress und den WordPress-Pods, eigene LAPI mit CNPG-Postgres, kein
  Console-Enrollment, **kein Bouncer**.
- **Client-IP-Voraussetzung:** Option A umgesetzt am 12.09.2026 — nginx-inc als
  DaemonSet, `externalTrafficPolicy: Local` (`infrastructure/base/ingress-nginx/values.yaml`).
- **Enforcement:** weiterhin offen; die Varianten 1–3 unten gelten unverändert.
- **Kontext überholt:** `docker.jit.land` (.15) ist seit 13.09.2026 abgeschaltet,
  GitLab (`gitlab01`) läuft inzwischen auf victorianix statt unter 192.168.2.17.

## Kontext

`docker.jit.land` (192.168.2.15) wird abgeschaltet. Der dortige CrowdSec-Edge-Bouncer
(Enforcement) wurde bereits additiv auf den Traefik-Edge in Potsdam (192.168.23.20)
migriert; das CrowdSec-„Gehirn" (LAPI/Detection) liegt weiterhin auf `gitlab01`
(192.168.2.17:8087) und `nc05` (192.168.2.217:8080).

Für Halbe ist geplant, dass der **Router direkt auf den Kubernetes-LoadBalancer**
(Cilium LB-IPAM, 192.168.2.246) geht — **ohne** den Potsdam-Traefik davor. Potsdam
bleibt nur noch Fallback.

Damit sieht der Potsdam-Bouncer den Direkt-Traffic nie. CrowdSec muss auf diesem Weg
**im Cluster** — am Ingress — sowohl erkennen als auch durchsetzen. Zwei
Stack-Eigenschaften stehen dem entgegen und bilden den Kern dieser Entscheidung:

1. **Client-IP wird ge-SNAT't.** Der Ingress läuft bewusst mit
   `externalTrafficPolicy: Cluster` (siehe `infrastructure/base/ingress-nginx/values.yaml`),
   weil der Cilium-L2-Announcer auf einem Node ohne nginx-Pod liegen kann (Ausfall
   22.07.). Preis laut eigenem Kommentar: die echte Client-Source-IP geht verloren.
   Ohne echte Client-IP ist CrowdSec blind (erkennt keine Angreifer) und würde im
   Zweifel interne Node-IPs bannen.
2. **Kein Node-Level-Bouncer möglich.** Die Nodes sind **Talos** (immutable, kein
   Paket-Install) und **Cilium eBPF / kube-proxy-replacement** umgeht nftables für
   LB-Traffic. Der klassische `crowdsec-firewall-bouncer-nftables` (wie auf .15 /
   Potsdam) ist hier **nicht** einsetzbar.

Weitere relevante Fakten:

- Ingress-Controller ist **nginx-inc** (`nginx.org`, `nginx-ingress`-Chart, Standard-
  `Ingress`-Ressourcen + `nginx.org/*`-Annotationen). **Kein OpenResty/Lua** → der für
  den Community-`ingress-nginx` übliche CrowdSec-Lua-Bouncer entfällt.
- `controller.enableSnippets: true` ist gesetzt (server/location-Snippets möglich).
- GitOps: ArgoCD-ApplicationSet erzeugt eine Application je `infrastructure/base/<component>`
  → ein neues Verzeichnis `infrastructure/base/crowdsec/` würde automatisch reconciled.
- Die k8s-Sites (u.a. Halbe-WordPress) werden **zweigleisig** erreicht: Potsdam-proxied
  (Client-IP = Potsdam) und künftig direkt (echte Client-IP). Derselbe Ingress bedient
  beide.

## Voraussetzung: echte Client-IP am Ingress (separat zu entscheiden)

Ohne diesen Fix ist jede Enforcement-Variante wirkungslos. Optionen:

- **A) nginx-inc als DaemonSet + `externalTrafficPolicy: Local`.** Jeder announcende
  Node hat dann einen lokalen nginx-Pod → der 22.07.-Ausfallmodus (Local verwirft auf
  pod-losem Node) kann nicht auftreten, und Local erhält die Client-IP. Einfachster,
  robuster Weg; hilft auch Logging/Geo/Rate-Limiting generell.
- **B) Cilium DSR (Direct Server Return).** Client-IP-Erhalt im eBPF-Datapath ohne
  DaemonSet. Muss gegen die Talos-/kube-proxy-replacement-Config verifiziert werden.
- **Nicht praktikabel:** PROXY-Protocol vom Halbe-Router (Home-Router spricht es nicht).

Entscheidung hierzu ist bewusst offen und wird getrennt getroffen. **Wichtig:** dieser
Fix ist **controller-unabhängig** — auch ein Umstieg auf Traefik (Variante 3) löst ihn
nicht.

## CrowdSec-Deployment im Cluster

Angriffe auf die k8s-Sites erscheinen in den **Ingress-Logs**, die die bestehenden
LAPIs (gitlab01/nc05) nie sehen. Der Cluster braucht daher ein **eigenes Gehirn**:

- CrowdSec-**Helm-Chart** als `infrastructure/base/crowdsec/` (ArgoCD-Appset).
- **Agent** (DaemonSet) tailt die nginx-Ingress-Pod-Logs, Collection `crowdsecurity/nginx`
  (+ Base), schreibt Decisions in eine **In-Cluster-LAPI**.
- Whitelists identisch zum Ansible-Stand: `192.168.2.0/24`, `192.168.23.0/24`, die
  DESY-Netze **und `192.168.23.20`** (Potsdam-Fallback nicht bannen).
- Detection funktioniert erst, wenn die Client-IP-Voraussetzung erfüllt ist.

## Enforcement-Varianten (Entscheidungsbedarf)

### Variante 1 — CrowdSec-nativer Front-Proxy im Cluster

Der K8S-LoadBalancer wird ein CrowdSec-fähiger Proxy vor nginx-inc:
Router → Proxy-LB → nginx-inc → Services.

- **Traefik** mit dem gleichen Bouncer-Plugin wie in Potsdam, **oder** **HAProxy** mit
  dem sehr ausgereiften CrowdSec-**SPOA**-Bouncer.
- **Aufwand:** mittel (zusätzliche Deployment-/Service-/LB-Ressourcen; LB-IP aus dem
  Pool .246–.249 wandert auf den Proxy).
- **Risiko:** niedrig — bewährtes, gut dokumentiertes Enforcement; wiederverwendet
  bekannte Tooling (Potsdam-Muster).
- **Preis:** ein zusätzlicher In-Cluster-Hop; zweiter Reverse-Proxy-Typ neben nginx-inc.

### Variante 2 — `auth_request` / AppSec in nginx-inc

nginx-inc bleibt Entrypoint; per server-Snippet ein `auth_request` auf die CrowdSec-
Remediation-/AppSec-Komponente, die gebannte bzw. bösartige Requests mit 403 abweist.

- **Aufwand:** mittel–hoch (Snippet + Bouncer/AppSec-Service verdrahten und testen).
- **Risiko:** mittel — für nginx-inc **nicht turnkey** (kein offizieller Lua-Bouncer);
  Snippet-Verhalten (Fail-open/Fail-closed, Timeouts, XFF) muss sauber verifiziert
  werden.
- **Preis:** kein Extra-Hop, am nativsten zum jetzigen Stack.

### Variante 3 — Ingress-Controller auf Traefik umstellen

nginx-inc wird als Ingress-Controller durch **Traefik** ersetzt; CrowdSec läuft dann als
**Bouncer-Plugin-Middleware — identisch zum Potsdam-Edge**.

- **Aufwand:** hoch/einmalig — alle `Ingress`-Ressourcen von `nginx.org/*`-Annotationen
  (`ssl-redirect`, `redirect-to-https`, `client-max-body-size`) auf Traefik-Middlewares
  bzw. IngressRoute migrieren; ExternalName/Resolver-Setup, cert-manager-Integration und
  ggf. Forward-Auth neu abbilden; revidiert die bewusste nginx-inc-Entscheidung.
- **Risiko:** mittel — Controller-Wechsel berührt **alle** Sites, nicht nur die
  CrowdSec-geschützten; dafür entfällt das nginx-inc-Sonderproblem komplett und das
  Enforcement ist bewährt (Potsdam).
- **Vorteil:** Enforcement quasi turnkey (nur Middleware); **ein Tooling für beide Edges**
  (Potsdam + k8s), gemeinsame Bouncer-Config-Muster, optional gemeinsame LAPI.
- **Löst NICHT** die Client-IP-Voraussetzung (controller-unabhängig, siehe oben).

### Verworfen

- **Node-Level nftables-Bouncer** — Talos immutable + Cilium eBPF (siehe Kontext).

## Federation (optional)

In-Cluster-LAPI bleibt autoritativ für die k8s-Sites. Bans können später zwischen den
LAPIs geteilt werden (LAPI-zu-LAPI bzw. zentrale LAPI), damit eine anderswo gesehene
Sperre überall greift. Für den ersten Schritt nicht erforderlich.

## Konsequenzen

- Sobald die Client-IP-Voraussetzung steht, ist CrowdSec-Detection am Ingress
  unabhängig von Potsdam wirksam.
- Enforcement-Variante bestimmt, ob ein zweiter Proxy-Typ (Variante 1) oder eine
  nginx-inc-Snippet-Integration (Variante 2) betrieben wird.
- Potsdam-Traefik-Bouncer bleibt für den Fallback-Weg zuständig; die In-Cluster-LAPI
  deckt den Direktweg ab.

## Offene Schritte

- Client-IP-Voraussetzung entscheiden (DaemonSet+Local vs. Cilium DSR) und umsetzen.
- Enforcement-Variante wählen: Front-Proxy (1) vs. nginx-inc-`auth_request` (2) vs.
  Controller-Umstieg auf Traefik (3). Bei (3) zusätzlich Migrationsumfang aller
  Ingress-Ressourcen einplanen.
- `infrastructure/base/crowdsec/` (Helm) anlegen: Agent + LAPI + nginx-Acquisition +
  Whitelists.
- Log-Format des Ingress prüfen (echte Client-IP / XFF muss im geparsten Feld landen).
- Optional: LAPI-Federation mit gitlab01/nc05.
- `PRODUCTION-READINESS.md` bei Umsetzung nachziehen.
