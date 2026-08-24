# ArgoCD rendert keine Helm-App mehr: `helm version -c`

## Symptom

19 von 36 Applications stehen auf `Sync: Unknown` bei gleichzeitig `Health: Healthy`.
Betroffen ist **jede App, deren Kustomization `helmCharts:` benutzt** — darunter
`infra-cilium`, `infra-cert-manager`, `infra-ceph-csi`, `infra-ingress-nginx`,
`infra-cnpg`, `infra-monitoring`, `app-paperless-ngx`, `app-forgejo`, `app-mastodon`.

In `.status.conditions` steht ein `ComparisonError`:

```text
Manifest generation error (cached): kustomize build <path> --enable-helm ...
Error: unknown shorthand flag: 'c' in -c
: unable to run: 'helm version -c --short' (is 'helm' installed?): exit status 1
```

`Healthy` ist hier **kein** Entwarnungssignal. Die Workloads laufen weiter, aber
GitOps ist blind: nichts aus Git kommt mehr im Cluster an, Drift wird weder erkannt
noch zurückgedreht. Letzter geglückter Sync von `app-paperless-ngx`: **02.08.2026**.

## Ursache

Der Repo-Server benutzt **nicht** das kustomize aus dem ArgoCD-Image. Der
Init-Container legt ein eigenes daneben:

```yaml
command: ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
```

`--with-kustomize` installiert ksops **und** ein kustomize; beide werden anschließend
per `volumeMounts` über `/usr/local/bin/` gemountet. Im laufenden Pod steht dadurch:

| Binary | Version | Herkunft |
|---|---|---|
| `kustomize` | **v5.3.0**+ksops.v4.5.1 | ksops-Image (`viaductoss/ksops:v4.5.1`) |
| `helm` | **v4.2.1** | ArgoCD-Image (`quay.io/argoproj/argocd:v3.5.1`) |

kustomize 5.3.0 prüft vor der Chart-Inflation die Helm-Version mit `helm version -c`.
Helm 4 hat das Kürzel `-c` (`--client`) entfernt ⇒ Abbruch, bevor `helm template`
überhaupt startet.

Ausgelöst wurde es vermutlich durch einen Renovate-Bump von `viaductoss/ksops`:
das Image bringt die kustomize-Version stillschweigend mit, ohne dass am Repo
sichtbar etwas an kustomize geändert wurde.

## Warum ArgoCDs eigenes kustomize die Lösung ist

ArgoCD v3.5.1 liefert **kustomize v5.8.1** aus, gepaart mit genau dem Helm 4, das im
selben Image liegt. Das Paar funktioniert. Zwei unabhängige Nachweise:

- Im `argocd-server`-Pod (dort ist nichts übergemountet) läuft `kustomize build
  --enable-helm` durch den Versionscheck bis ins echte `helm template`.
- In der Devshell des Repos (kustomize 5.8.1 + helm 4.2.3 + ksops) bauen **alle 19
  betroffenen Pfade mit exit 0** — inklusive SOPS-Entschlüsselung.

## Fix

`--with-kustomize` streichen und den kustomize-`volumeMount` entfernen; nur noch das
`ksops`-Binary aus dem Image nehmen.

```diff
-      command: ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
+      command: ["/usr/local/bin/ksops", "install", "/custom-tools"]
   volumeMounts:
-    - mountPath: /usr/local/bin/kustomize
-      name: custom-tools
-      subPath: kustomize
     - mountPath: /usr/local/bin/ksops
```

**An zwei Stellen synchron**, sonst driftet der Terraform-Bootstrap gegen die Helm-Values:

- `infrastructure/base/argocd/values.yaml` (Command + `volumeMounts`)
- `infrastructure/tofu/talos-cluster/envs/kellerIO/argocd.tf` (~Z. 80 und ~Z. 96)

Nebeneffekt: künftige ksops-Bumps können die kustomize-Version nicht mehr anfassen.
Damit verschwindet die Fehlerklasse, nicht nur dieser Fall.

**Henne-Ei:** `infra-argocd` steht selbst auf `Unknown`, ArgoCD kann sich also nicht
selbst herausreparieren. Der Fix muss out-of-band rein — `tofu apply` oder ein
direkter Patch am `argocd-repo-server`-Deployment.

## Vor dem Fix: Drift-Inventur

Zwischen dem 02.08. und dem Fix ist alles, was von Hand geändert wurde, unversioniert.
Der erste erfolgreiche Sync rollt es zurück. Inventur vom **21.08.2026**
(`kustomize build` aus `origin/main` gegen live, `kubectl diff`):

**Driftfrei (7):** `app-gatus`, `app-gatus-public`, `infra-ceph-csi`, `infra-cnpg`,
`infra-crowdsec`, `infra-csi-driver-smb`, `infra-kite`

**Vor dem Sync klären:**

| App | Befund | Risiko |
|---|---|---|
| `infra-mariadb-operator` | Live läuft der Operator in **`mariadb-system`**, Git rendert ihn nach **`mariadb-operator`** (beide Namespaces existieren) | **Hoch** — Sync stellt einen *zweiten* Operator daneben; zwei Instanzen auf denselben MariaDB-CRs |
| `app-mastodon` | Live gar nicht deployt; Git enthält den kompletten Stack (web, streaming, sidekiq, CNPG-Cluster, valkey, Jobs, 6 Secrets) | **Hoch** — Sync fährt Mastodon erstmalig hoch |
| `infra-cilium` | `cilium-ca`, `hubble-relay-client-certs`, `hubble-server-certs` weichen von live ab | **Mittel** — einmalige CA-/Hubble-Rotation, mTLS bricht bis alle Komponenten neu starten. Renders sind reproduzierbar, also keine Dauer-Drift |
| `infra-monitoring` | `vm-…-operator-validation`-TLS-Secret + `caBundle` weichen ab | **Mittel** — Webhook-Zertifikat wird getauscht |
| `app-collabora` | nur `confighash` / ConfigMap-Inhalt | Niedrig |
| `app-paperless-ngx` | nur `PAPERLESS_SOCIALACCOUNT_PROVIDERS` im Secret | Niedrig |
| `infra-ingress-nginx` | nur Labels an einem Lease | Niedrig |
| `infra-metrics-server` | eine RoleBinding in `kube-system` | Niedrig |
| `infra-argocd`, `infra-cert-manager`, `app-forgejo` | ausschließlich **Helm-Hook-Ressourcen** (`helm.sh/hook: test/post-install/pre-install`), live nicht vorhanden weil einmalig und nach Erfolg gelöscht | Niedrig, aber vorher verstehen |

Empfohlene Reihenfolge: Drift klären → Git nachziehen → Repo-Server fixen → **App für
App** syncen, nicht alle 19 auf einmal.

## Fallstricke beim Nachstellen der Inventur

- **Nicht aus dem Working-Tree rendern.** Alle Applications tracken `main`. Ein
  Feature-Branch führt in die Irre: hier sah es kurzzeitig so aus, als würde ein Sync
  Paperless von 2.20.15 auf 2.20.6 **downgraden** — der Stand kam aus dem lokalen
  Branch, `origin/main` war die ganze Zeit korrekt. Sauberen Worktree anlegen:
  `git worktree add --detach <dir> origin/main`.
- **`kubectl diff` braucht den Ziel-Namespace.** Die Helm-gerenderten Objekte tragen
  **keinen** `namespace:` — ArgoCD setzt ihn über `spec.destination.namespace`.
  Ohne `-n <destination>` vergleicht kubectl gegen `default` und meldet praktisch
  alles als neu (Paperless: 289 statt 4 Zeilen).
- **Manifeste vorher aufteilen.** Objekte mit explizitem Namespace (z. B. Cilium nach
  `kube-system`) und namespace-lose Objekte müssen getrennt gediffed werden, sonst:
  `the namespace from the provided object "kube-system" does not match ...`.
- **`kubectl diff` braucht ein externes `diff`.** Fehlt es im PATH, kommt
  `failed to run "diff": executable file not found`. Lösung:
  `KUBECTL_EXTERNAL_DIFF="/usr/bin/diff -u -N"`.

## Ausgang (24.08.2026)

Behoben. Ablauf und die Punkte, die beim Nachstellen Zeit gekostet hätten:

1. **Auto-Sync zuerst fleet-weit einfrieren** (PR #116). Alle Applications teilen sich
   *eine* `syncPolicy` aus dem jeweiligen ApplicationSet-Template — es gibt keinen
   Per-App-Override. Ohne diesen Schritt hätten nach der Reparatur **alle 19 blinden
   Apps gleichzeitig gesynct und geprunt**, statt App für App. `root` und beide
   ApplicationSets sind reines YAML ohne `helmCharts:` und rendern auch im kaputten
   Zustand, der Freeze ließ sich also ganz normal per GitOps ausrollen.
2. Fix in Git: PR #117 (`values.yaml`) und keller-IO/infrastructure#7 (`argocd.tf`).
3. **Aktivierung out-of-band per `kubectl patch`** am `argocd-repo-server`-Deployment.

### `tofu apply` war NICHT der Aktivierungsweg — auch nicht mit `-target`

`tofu plan -target=helm_release.argocd` ergab **`2 to add, 8 to change, 2 to destroy`**:
`kellerio-wrk1` und `kellerio-wrk4` wären zerstört und neu gebaut worden. `-target`
zieht `module.nodes` als Dependency mit, und `-exclude` ist damit nicht kombinierbar
(OpenTofu 1.12.5: *"mutually-exclusive"*); `-exclude=module.nodes` allein schließt
`helm_release.argocd` transitiv gleich mit aus (`No changes`).

**Ursache war die tfvars, nicht der State.** `node_name` erzwingt beim Proxmox-Provider
eine Ersetzung, und die tfvars nannten falsche Hosts: wrk1 liegt real auf `pve`
(tfvars: `cloud67`), wrk4 auf `cloud62` (tfvars: `cloud59`). Verifiziert per
`pvesh get /cluster/resources --type vm` **und** Tofu-Refresh. Nach der Korrektur:
`0 to add, 9 to change, 0 to destroy`.

> **Falle:** `tofu state show` liest den *gespeicherten* State und meldete weiterhin
> `cloud67`/`cloud59`. Nur der Refresh im `plan` zeigt die Realität.

Weiterhin offen: wrk4s Disk liegt auf Ceph (`vmimages`), `vm_storage_id` ist global
`local-zfs` — der Plan will sie migrieren. `talos-proxmox-nodes` setzt
`datastore_id = var.vm_storage_id` fest (`vms.tf:39,49,79`) und kennt Per-Node-Storage
nur für `extra_disk`.

### Der gecachte Fehler verschwindet nicht von allein

Nach dem Patch liefen im Pod die richtigen Binaries (`kustomize v5.8.1` + `helm v4.2.1`),
**alle 19 Apps standen trotzdem weiter auf `Unknown`** — die Meldung lautet
`Manifest generation error (CACHED)`. Es braucht pro App einen Hard-Refresh:

```bash
kubectl patch application <name> -n argocd --type=merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

### Ergebnis: 0 Unknown, 30 Synced, 6 OutOfSync

Deutlich weniger Drift als befürchtet. `infra-argocd` steht selbst auf `Synced` — der
Patch deckt sich exakt mit `values.yaml`. Die sechs Verbliebenen:
`infra-mariadb-operator`, `app-mastodon`, `infra-cilium`, `infra-monitoring`,
`infra-metrics-server`, `app-collabora`.

### Nebenbefund: Ressourcen im falschen Namespace

In drei Infra-Apps landen Objekte, die laut Chart in einen **festen** Namespace gehören
(meist `kube-system`), stattdessen im Destination-Namespace der Application — der kommt
im ApplicationSet 1:1 aus `{{.path.basename}}`.

Nachgemessen bei `infra-metrics-server`: `RoleBinding metrics-server-auth-reader`
existiert live in `metrics-server` (26 Tage alt), aber **nicht** in `kube-system`, wo sie
die Role `extension-apiserver-authentication-reader` binden müsste — die Bindung ist
damit funktionslos. **Hier hat Git recht und Live ist kaputt**, also genau umgekehrt zu
`infra-mariadb-operator`, wo der Operator produktiv in `mariadb-system` läuft und Git
nach `mariadb-operator` rendert. Betrifft `metrics-server`, `monitoring`,
`mariadb-operator`.

## Siehe auch

- `docs/learnings/argocd-dauerhaft-outofsync.md` — der *andere* Sync-Fehlerzustand
  (`OutOfSync` durch Defaulting-Felder). Hier geht es um `Unknown` durch Render-Abbruch.
