# keller-main ueber NetBird pruefen

## Zugriffspfad

`~/.kube/keller.yaml`, Kontext `keller-main`, zeigt auf
`https://keller-main.netbird-kubeapi-proxy.netbird.selfhosted.`.
Der zustaendige Tenant ist **netbird.jit.services**, lokales Profil `jit`.
Das Homelab-Profil `default` und der vorhandene globale NetBird-MCP zeigen auf
`netbird.f4mily.net`; damit laesst sich der jit-Tenant nicht diagnostizieren.

Die Proxy-Identitaet uebersetzt NetBird-User-/Peer-Gruppen in Kubernetes-Gruppen.
Ein Kubeconfig-Dateiname oder ein opakes Token beweist deshalb keine
Read-only-Berechtigung. Agenten brauchen `k8s_readonly`, ohne Mitgliedschaft in
`k8s_admin` oder `k8s_ops`. Die Rollen stehen in
`infrastructure/base/netbird/rbac.yaml`. Berechtigungen mit `auth whoami` und
`auth can-i` pruefen, bevor der Kontext fuer Clusterinspektion benutzt wird.

## Beobachtung am 18.10.2026

- Aktives Profil `jit`; Management, Signal und Relay verbunden.
- DNS loeste den Proxy zu `100.88.175.39`, `100.88.205.33`, `100.88.244.129`
  und `100.88.106.190` auf. Alle vier TCP/443-Tests liefen in einen Timeout.
- Drei Proxy-Peers hatten danach frische WireGuard-Handshakes, aber nur etwa
  124 Byte empfangen gegenueber rund 1 KiB gesendet.
- Das ist mit ACL-Filterung vereinbar; **eine konkrete fehlerhafte Policy ist
  nicht bewiesen**. Management-API-Inspection scheiterte am fehlenden passenden
  Age-Key fuer das verschluesselte Operator-Credential.
- `KELLER_KUBERNETES_MCP_AUTH` war nicht gesetzt; keller-MCP-Tools waren in dieser
  Sitzung nicht verfuegbar, sein oeffentlicher Endpunkt ebenfalls unerreichbar.

Diese Beobachtung belegt weder einen Cluster-Ausfall noch eine fehlende
Kubernetes-Rolle. Der Fehler liegt bereits vor einem erfolgreichen API-Aufruf.
Peer-Adressen und Policy-Zustand sind Momentaufnahmen; erneut pruefen.

## Diagnose und Reparatur

1. `netbird status -d`: Profil, Tenant, DNS, Peer-Verbindungen pruefen. Ein
   frischer Handshake beweist nur den Tunnel, keine erlaubte TCP-Verbindung.
   Das Profil nicht nebenbei wechseln; andere Verbindungen koennen daran haengen.
2. Im **jit-Dashboard** pruefen: Client-Peer `infinityp10` (damals
   `100.88.186.65`) beziehungsweise sein User gehoert zu `k8s_readonly`.
   Keine Admin-/Ops-Gruppen fuer den Agent-Zugang.
3. Die aktiven `clusterproxy-keller-main-*`-Peers muessen Mitglied der
   Zielgruppe `k8s_api_proxy` sein. Eine aktivierte Policy muss die gewuenschten
   Read-only-Clients mit dieser Zielgruppe auf TCP/443 verbinden. Auch Posture
   Checks und Peer-Approval pruefen. Nicht auf `All` erweitern.
4. Gruppen und Policy werden im NetBird-Management verwaltet, nicht durch diese
   GitOps-Aenderung. Keine `Group`-CRs fuer existierende Gruppen anlegen: der
   Operator kann sonst Duplikate erzeugen oder bei Prune Management-Gruppen
   loeschen. Eine `NBPolicy` mit bloss `spec.ports` bildet diese Proxy-Policy
   nicht korrekt ab; siehe Kommentare in `netbird-config.yaml`.
5. Erst nach TCP/TLS-Erfolg mit dem expliziten Kontext die Identitaet pruefen:

   ```sh
   kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main --request-timeout=10s auth whoami
   kubectl --kubeconfig ~/.kube/keller.yaml --context keller-main --request-timeout=10s auth can-i --list
   ```

   Danach nur mit bestaetigten Leserechten Nodes, PDBs, CNPG, CSI und
   ArgoCD-Status pruefen. `get secrets`, Exec, Admin-Kubeconfigs und mutierende
   Clusteraufrufe gehoeren nicht zur Zugangspruefung.
6. Der lokale Kubeconfig hatte `insecure-skip-tls-verify: true`. Nach erreichbarem
   Proxy dessen vorgesehene TLS-Vertrauenskette pruefen und in einer dedizierten
   Read-only-Kubeconfig korrekt konfigurieren; das Flag nicht ohne Kenntnis der
   Proxy-Zertifikate blind entfernen. NetBird-Tunnelverschluesselung ersetzt
   nicht automatisch die TLS-Pruefung eines beliebigen Endpunkts.

Die NetBird-Injection bleibt Opt-in ueber `netbird.io/webhook=enabled`.
`kube-system` darf dieses Label nicht bekommen. Der Talos-Prepare-Check wertet
die tatsaechlichen Live-Webhook-Selectoren vor jedem Drain aus.

[Offizielle NetBird-Dokumentation zum API-Proxy](https://docs.netbird.io/use-cases/kubernetes/api-server-proxy).
