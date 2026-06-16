# Runbook — Inbetriebnahme (Blaupause → Produktion)

Sequentielle Go-Live-Checkliste über **beide** Repos:
`infrastructure` (Talos/Tofu) und `kubernetes-gitops` (Workloads).
Detail-Erklärungen pro Bereich: [`docs/PRODUCTION-READINESS.md`](../PRODUCTION-READINESS.md).

Reihenfolge ist verbindlich: Infra erst, dann Secrets, dann GitOps reconcilen,
dann pro-App-Werte. Pfade relativ zum jeweiligen Repo-Root.

Globale Suche nach offenen Platzhaltern (in beiden Repos):
```bash
grep -rn --exclude-dir=.git --exclude-dir=.terraform --exclude-dir=charts \
  -E "CHANGE ?ME|REPLACE_?ME|jit\.platzhalter|TODO" .
```

---

## 0. Vorbereitung — Tooling & Schlüssel

- [ ] Dev-Shell je Repo: `nix develop` (liefert tofu, talosctl, kubectl, kustomize,
      helm, sops, age, kubeconform, just, argocd).
- [ ] **Ein** age-Keypair für SOPS erzeugen (gilt für *beide* Repos):
      ```bash
      age-keygen -o ~/.config/sops/age/keys.txt
      export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
      grep 'public key' ~/.config/sops/age/keys.txt   # -> age1...
      ```
- [ ] Public Key in beide `.sops.yaml` eintragen
      (`infrastructure/tofu/talos-cluster/envs/kellerIO/.sops.yaml`,
      `kubernetes-gitops/.sops.yaml`).

> Wichtig: Tofu mountet denselben privaten age-Key per KSOPS in den Argo-CD
> repo-server (`argocd.tf`, Variable `sops_age_private_key`). Wer hier einen
> anderen Key nimmt, kann verschlüsselte `*.sops.yaml` im Cluster nicht entschlüsseln.

---

## 1. Infrastructure — Talos-Cluster (Repo: `infrastructure`)

**Dateien:** `tofu/talos-cluster/envs/kellerIO/cluster.auto.tfvars`,
`.../secrets.enc.yaml`, `.../argocd.tf`

- [ ] Offene TODOs in `cluster.auto.tfvars` setzen:
  - `proxmox_endpoint` (echter cloud5x/6x-Host)
  - `vm_storage_id`, `iso_storage_id` (ISO = **shared** Storage, von allen Hosts erreichbar)
  - `argocd_repo_url`, `git_username`, `argocd_bootstrap_path` auf reales GitOps-Repo
- [ ] Secrets (SOPS) anlegen — proxmox-Token, git-Token, age-Key:
      ```bash
      cd tofu/talos-cluster/envs/kellerIO
      cp secrets.enc.yaml.example secrets.yaml   # Werte eintragen
      just secrets-encrypt                       # -> secrets.enc.yaml
      rm secrets.yaml
      ```
- [ ] Provisionieren:
      ```bash
      just init
      just validate
      just plan      # reviewen!
      just apply
      ```
- [ ] kubeconfig/talosconfig werden ins env-Verzeichnis geschrieben (`outputs.tf`):
      ```bash
      export TALOSCONFIG=$PWD/talosconfig
      export KUBECONFIG=$PWD/kubeconfig
      kubectl get nodes -o wide      # cp1-3 + wrk1-3 Ready?
      talosctl -n 192.168.2.81 health
      ```

> `tofu apply` installiert auch Argo CD und legt das Repo-Secret + den age-Key an
> (`argocd.tf`). GitOps-Reconcile startet danach automatisch.

---

## 2. GitOps-Grundlagen (Repo: `kubernetes-gitops`)

**Dateien:** `clusters/main/{root-app,appset-infrastructure,appset-apps}.yaml`,
`infrastructure/base/argocd/*`

- [ ] `repoURL` in `clusters/main/*.yaml` auf reales Repo (aktuell `git.f4mily.net/...`).
- [ ] `kustomize-helm` CMP im repo-server registriert (ApplicationSets nutzen
      `plugin.name: kustomize-helm`) — siehe PRODUCTION-READINESS §2.
- [ ] Root-App ausrollen (falls nicht schon durch Tofu):
      ```bash
      kubectl apply -f clusters/main/root-app.yaml
      argocd app list
      ```

---

## 3. Secrets befüllen (Repo: `kubernetes-gitops`)

- [ ] **Alle** `*.sops.yaml` mit echten Werten füllen + verschlüsseln:
      ```bash
      just encrypt path/to/secret.sops.yaml     # = sops --encrypt --in-place
      just secrets-check                         # kein Klartext im git
      ```
- [ ] Liste der betroffenen Dateien:
      ```bash
      find . -name '*.sops.yaml'
      ```

Betroffen u.a.: `infrastructure/base/authentik/secret.sops.yaml`,
`infrastructure/base/cert-manager/cluster-issuer.sops.yaml`,
`apps/base/{kimai,roundcube,paperless-ngx,forgejo,mastodon,wordpress,gatus,kite,collabora,renovate}/secret.sops.yaml`.

---

## 4. Domain, Netzwerk, Ingress & DNS

**Dateien:** `apps/overlays/main/cluster-config.yaml`, alle `**/ingress.yaml` &
`values.yaml` (`hosts:`), `infrastructure/base/{ingress-nginx,cilium}/values.yaml`

- [ ] Domain global ersetzen (vorher Diff reviewen!):
      ```bash
      grep -rl jit.platzhalter . | xargs sed -i 's/jit.platzhalter/DEINE-DOMAIN.tld/g'
      ```
- [ ] LoadBalancer-IP-Quelle: Cilium LB-IPAM **oder** MetalLB-Pool.
- [ ] Cilium `k8sServiceHost/Port` auf KubePrism (127.0.0.1:7445), `kubeProxyReplacement: true`.
- [ ] DNS-Records (A/AAAA bzw. Wildcard) für alle Hosts aus `cluster-config.yaml` → LB-IP.

---

## 5. Storage (Ceph)

**Dateien:** `infrastructure/base/storage/*`, jedes `storageClassName:` in Apps

- [ ] StorageClass-Namen gegen reales Ceph verifizieren (`ceph-rbd` RWO, `ceph-fs` RWX,
      `ceph-bucket` für OBC). Provisioner in `storageclasses.yaml` anpassen
      (`rook-ceph.*` vs. externes ceph-csi).
- [ ] RWX (CephFS) dort bestätigen, wo Replicas teilen (paperless media, wordpress wp-content).
- [ ] Smoke-Test:
      ```bash
      kubectl get sc
      kubectl apply -f - <<'EOF'   # Test-PVC, danach löschen
      apiVersion: v1
      kind: PersistentVolumeClaim
      metadata: { name: test-rbd }
      spec: { accessModes: [ReadWriteOnce], storageClassName: ceph-rbd, resources: { requests: { storage: 1Gi } } }
      EOF
      kubectl get pvc test-rbd    # -> Bound?
      ```

> iSCSI nicht nötig: Ceph RBD nutzt krbd, CephFS den Kernel-Client.

---

## 6. TLS / cert-manager

**Dateien:** `infrastructure/base/cert-manager/cluster-issuer.sops.yaml`

- [ ] DNS-Provider-Token setzen + verschlüsseln, `email:`/`dnsZones:` real.
- [ ] Optional Staging-Issuer gegen LE-Ratelimits.
- [ ] Prüfen:
      ```bash
      kubectl get clusterissuer
      kubectl get certificate -A      # READY=True?
      ```

---

## 7. Datenbanken & Cache

**Dateien:** `infrastructure/base/{cnpg,mariadb-operator}/`,
`apps/base/*/database.yaml`, `apps/base/*/cache.yaml`

- [ ] DB-Passwörter in `secret.sops.yaml` ↔ App-Env identisch.
- [ ] HA für Prod: CNPG `instances: 1→3`, MariaDB `replicas: 1→3`, Valkey `replicas: 1→3`.
- [ ] `mastodon-redis`-Passwort (Valkey `requirepass`) ↔ App identisch.
- [ ] `storageClassName` je DB/Cache final.
- [ ] Prüfen:
      ```bash
      kubectl get cluster.postgresql.cnpg.io -A
      kubectl get mariadb -A
      ```

---

## 8. Identity / OIDC (Authentik)

**Dateien:** `infrastructure/base/authentik/*`, `.../blueprints/*`

- [ ] `authentik-secret` (SECRET_KEY, Bootstrap-Creds) füllen.
- [ ] Pro App `client_id`/`client_secret` in Blueprint **und** App-Secret identisch.
- [ ] `redirect_uris` auf reale Domain.
- [ ] Login + ein OIDC-Flow (z.B. forgejo) manuell testen.

---

## 9. Observability & Backup/DR

**Dateien:** `infrastructure/base/monitoring/values.yaml`, `apps/base/*/backup.yaml`,
`apps/base/*/database.yaml`

- [ ] Grafana-Admin-Passwort aus SOPS statt Klartext.
- [ ] **Alertmanager-Receiver** konfigurieren (aktuell `"null"`).
- [ ] S3-Buckets (`cnpg-<app>`, `mariadb-<app>`) anlegen, `<app>-backup-s3`-Secrets füllen,
      `endpointURL` (`s3.jit.platzhalter`) auf reale RGW-URL.
- [ ] PVC-Daten-Backup (Ceph-Snapshots/Velero) — DB-Backup deckt nur die DB.
- [ ] **Restore einmal testen** und Runbook hier in `docs/runbooks/` ablegen.

---

## 10. CI, Renovate & Mail

- [ ] Forgejo-Actions-Runner registrieren (`get_runner_registration_token`).
- [ ] Renovate-Token + `endpoint`/`gitAuthor` (`apps/base/renovate/{secret.sops.yaml,config.js}`).
- [ ] Externen IMAP/SMTP für roundcube/mastodon/paperless setzen (kein Mailserver im Cluster).

---

## 11. Pro-App-Feinschliff

Tabelle mit app-spezifischen Restschritten: PRODUCTION-READINESS §14.

```bash
ls apps/base/                       # Basis pro App
ls apps/overlays/main/              # Cluster-Patches (werden von appset-apps deployed)
```

---

## 12. Abnahme vor Go-Live

Lokal (Repo `kubernetes-gitops`) vor dem ersten Sync:
```bash
just build           # kustomize build --enable-helm über alle overlays
just test            # + kubeconform Schema-Validierung
just lint            # yamllint
just secrets-check   # keine Klartext-*.sops.yaml
```

Im Cluster:
```bash
argocd app list                                  # alle Synced/Healthy?
kubectl get applications -n argocd
kubectl get pods -A | grep -vE 'Running|Completed'   # nichts übrig?
```

- [ ] Keine offenen Platzhalter mehr (Grep aus dem Kopf dieser Datei = leer).
- [ ] Alle Argo-Apps **Synced + Healthy**.
- [ ] Ein Ende-zu-Ende-Test pro exponierter App (DNS → TLS → OIDC-Login).
- [ ] Restore-Test bestanden.
