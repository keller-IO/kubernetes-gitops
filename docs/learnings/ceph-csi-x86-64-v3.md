# ceph-csi 3.18 crasht auf x86-64-v2-VMs und legt Goloom lahm

## Symptom

Am 26.10.2026 war Goloom down: der Pod hing mit `Multi-Attach error` auf dem
RBD-Volume. Alle neuen ceph-csi-Pods mit `quay.io/cephcsi/cephcsi:v3.18.1`
(auf wrk1, wrk2, wrk5) endeten in `CrashLoopBackOff` mit
`Fatal glibc error: CPU does not support x86-64-v3`. Die alten v3.17-Pods auf
den übrigen Nodes liefen weiter.

## Ursache

Renovate-PR #394 hob beide Charts (`ceph-csi-rbd`, `ceph-csi-cephfs`) von 3.17.0
auf 3.18.1, ArgoCD rollte aus. Die v3.18-Images sind für x86-64-v3 gebaut. Die
Nodes sind Talos-VMs, deren virtuelle CPU laut glibc kein x86-64-v3
bietet (konkreter VM-CPU-Typ nicht geprüft). Weder Chart-Values noch Diff zeigen diese Hardware-Voraussetzung;
CI rendert nur Manifeste und startet keine Images.

## Auswirkung

Das RBD-Nodeplugin auf wrk2 crashte, konnte das Volume nicht mehr unstagen,
und das Volume ließ sich nicht von wrk2 lösen. Der Goloom-Pod auf einem anderen
Node scheiterte deshalb mit Multi-Attach. Ein gesunder Rollout-Teil schützt
nicht: ein einzelnes kaputtes Nodeplugin blockiert jedes Volume auf seinem Node.

## Behebung

Beide Charts in `infrastructure/base/ceph-csi/kustomization.yaml` zurück auf
3.17.0, Renovate-Hold in `renovate.json` (`allowedVersions` `^3\.17\.\d+$` für
`ceph-csi-rbd` und `ceph-csi-cephfs`). Nach dem Sync die Nodeplugin-Pods auf
wrk1/wrk2/wrk5 neu starten lassen und prüfen, dass das Volume sich löst.

## Prävention

- Der Renovate-Hold verhindert weitere 3.18+-Vorschläge. Aufheben erst, wenn
  der Proxmox-CPU-Typ aller Nodes x86-64-v3 bietet (`host` oder `x86-64-v3`).
- Vor Bumps von Node-nahen Komponenten (CSI, CNI, Kernel-nahe Images) die
  Mindest-Mikroarchitektur der neuen Images prüfen (Release Notes, Base-Image).
- CSI-Nodeplugins sind kritisch für alle Volumes ihres Nodes: Bumps nicht
  ungeprüft mergen, Rollout nach dem Merge beobachten.
- Ein CI-Guardrail wurde nicht ergänzt: der Fehler zeigt sich erst zur
  Laufzeit auf der Hardware, die Version allein ist kein prüfbares Muster
  außerhalb von Renovate.
