# clusters/main — ArgoCD entry points

Bootstrap order (one-time, manual on a fresh cluster):

1. Install ArgoCD itself (Helm or `kubectl apply`) — see `infrastructure/base/argocd/`.
2. Create the age key secret so the repo-server (KSOPS) can decrypt SOPS secrets:
   `kubectl -n argocd create secret generic sops-age --from-file=keys.txt=age.agekey`
3. Apply the root app: `kubectl apply -f clusters/main/root-app.yaml`.

`root-app.yaml` is an *app-of-apps*. It deploys:
- `projects.yaml`        — ArgoCD AppProjects (`infrastructure`, `apps`)
- `appset-infrastructure.yaml` — one Application per `infrastructure/base/*`
- `appset-apps.yaml`     — one Application per `apps/overlays/main/*`

Sync waves keep ordering sane: infrastructure (CNI/CRDs/operators) before apps.
Fine-grained intra-infra ordering is a production TODO — see `docs/PRODUCTION-READINESS.md`.
