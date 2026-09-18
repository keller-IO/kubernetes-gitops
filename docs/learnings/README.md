# Learnings

Destillierte Erkenntnisse aus Operationen, die nicht beim ersten Versuch funktioniert haben.
Format und Kriterien: siehe AGENTS.md → „Operational Learnings".

- [Agent-Guardrails](agent-command-guardrails.md) — Agenten arbeiten via GitOps/PR;
  Live-Cluster-Zugriff bleibt read-only und CI blockiert gefaehrliche Automationsmuster.
- [ArgoCD dauerhaft OutOfSync](argocd-dauerhaft-outofsync.md) — nicht Drift, sondern
  vom API-Server/Operator ergaenzte Default-Felder (`volumeMode`, `nodePort`, `caBundle`).
- [Collabora-HPA skalierte auf 55 Replicas](collabora-hpa-runaway.md) — Chart-Default-HPA
  ignorierte replicaCount und legte am 28.07.2026 ArgoCD, cert-manager und ceph-csi lahm.
- [Cloud-dev Proxy-Cutover](cloud-dev-proxy-cutover.md) — Single-File-Bind-Mounts
  folgen keinem atomaren Host-Rename; Nextcloud muss zusaetzlich dem Pod-CIDR
  des neuen Proxy-Hops vertrauen.
- [EuroOffice-Connector behält transiente Verbindungsfehler](eurooffice-stale-settings-error.md)
- [Externes CephFS nach Node-Stall](external-cephfs-client-stall-recovery.md) — Node
  und Mount koennen gesund wirken, obwohl die MDS-Session verworfen wurde; erst
  ein echter Cross-Node-I/O-Test bestaetigt die Recovery.
- [NIC 5.x verwirft Ingress bei ungueltiger Annotation](nginx-ingress-5x-annotation-strictness.md)
  — `proxy-buffering: "off"` statt `"false"` legte radio.jit.services still auf 404.
- [Flurfunk: DNS/TLS-Kette mit drei unabhaengigen Fehlern](flurfunk-dns-and-http01-chain.md)
  — kaputte BIND-Zonen-Stanza, negatives dnsmasq-Caching, und HTTP-01 kollidiert
  mit dem eigenen Ingress beim nginx.org-Controller (Fix: DNS-01 statt Mergeable-Ingress).
- [root-app.yaml: eigene include-Liste greift nicht automatisch](root-app-self-reference-not-auto-applied.md)
  — eine neue Application in der include-Liste braucht nach dem Merge einen
  einmaligen manuellen `kubectl apply -f clusters/main/root-app.yaml`.
- [Paperless-CLI ausserhalb von s6](paperless-cli-without-s6.md) — die
  Convenience-Wrapper erwarten `/init`; Kubernetes-Jobs rufen `manage.py`
  stattdessen explizit als Benutzer `paperless` auf.
- [Roundcube: pgloader-Schema-Typen](roundcube-pgloader-schema-types.md)
- [Mailman: Volltextindex nach Datenmenge planen](mailman-whoosh-reindex-performance.md)
  — gleich grosse ID-Shards fuehrten bei 4,3 GiB ungleich verteiltem Mailtext zu
  einem System-OOM; lokales Scratch, Byte-Limits, persistente Checkpoints und
  ein Xapian-Benchmark sind der belastbare Weg.
- [Yealink T46S: OEM-Firmware blockiert Remote Phone Book](yealink-t46s-oem-phonebook.md)
  — funktionierender Fallback ist der einmalige Import ins lokale Telefonbuch.
