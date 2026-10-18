# ArgoCD prunt die PVC, wenn eine App die Quelle wechselt

## What went wrong

Am 17.10.2026 hat #238 Goloom vom eingecheckten Chart (`apps/vendor/goloom`) auf
das Upstream-Chart als zweite Quelle der Application umgestellt. Um 07:22:39 UTC
synchronisierte `app-goloom` den Merge-Commit `6152a35` noch als Application mit
nur einer Quelle: Das Overlay enthielt kein Chart mehr, die neue Spec mit zwei
Quellen aus der ApplicationSet war noch nicht angekommen. Mit `prune: true` hat
ArgoCD daraufhin Deployment **und PVC `goloom-data`** geloescht. Zwei Minuten
spaeter legte die neue Spec das Deployment wieder an; die PVC hing in
`Terminating`, weil der neue Pod sie referenzierte (`pvc-protection`), und
Goloom blieb gut drei Stunden down. Mit `reclaimPolicy: Delete` haette jedes
Wegraeumen des Pending-Pods das RBD-Image endgueltig geloescht.

## Why it failed

- Repo-Inhalt und Application-Spec kommen ueber zwei getrennte Wege (App-Sync vs.
  ApplicationSet-Controller). Dazwischen rendert ArgoCD einen Zwischenstand, in
  dem chart-erzeugte Ressourcen fehlen, und prunt sie.
- Eine vom Chart erzeugte PVC traegt keine ArgoCD-Schutz-Annotation; das
  Upstream-Chart bietet dafuer auch keinen Wert an.
- Die StorageClass `ceph-rbd` provisioniert mit `reclaimPolicy: Delete`.

## The correct approach

Wiederherstellung (so gelaufen): PV auf `Retain` patchen, RBD-Snapshot anlegen,
`argocd-application-controller` kurz auf 0, Deployment auf 0, `pvc-protection`-
Finalizer der alten PVC entfernen (abgeschlossene Backup-Pods referenzierten sie
noch), `claimRef.uid`/`resourceVersion` aus dem PV entfernen, PVC gleichen Namens
mit `volumeName` anlegen, Controller wieder hoch. Danach zeigt ArgoCD
`OutOfSync`, weil es bei der Client-Side-Apply-Migration `volumeName` uebernimmt
und leeren will (unveraenderlich); die `managedFields` der PVC einmalig
zuruecksetzen.

Dauerhaft: Die PVC einer zustandsbehafteten App liegt im eigenen Base
(`persistence.existingClaim`) und traegt
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`. Kein `volumeName` in
Git, damit ein Restore auf einem neuen Cluster frisch provisioniert.

## Prevention

- Goloom: `apps/base/goloom/pvc.yaml`.
- Vor jedem Quellenwechsel einer App (vendored Chart -> Git-/Helm-Quelle, Single-
  -> Multi-Source) pruefen, dass alle PVCs `Prune=false` tragen, oder automatisches
  Prune fuer die App waehrend der Umstellung aussetzen.
- CI: `scripts/ci/check-pvc.py` verlangt fuer gerenderte PVCs in `apps/` exakt
  `Prune=false,Delete=false`. Die 14 bisherigen Luecken sind seit 18.10.2026
  in den Manifesten bzw. nativen Helm-Annotationswerten geschlossen;
  `scripts/ci/known-gaps/unprotected-pvcs.txt` enthaelt keine Ausnahmen.
  Vor einem Quellenwechsel muss die Annotation bereits synchronisiert sein.
  Namespace-Loeschung und Storage-Ausfaelle deckt dieser Argo-Schutz nicht ab.
