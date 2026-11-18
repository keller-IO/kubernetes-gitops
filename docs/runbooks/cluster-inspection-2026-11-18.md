# KellerIO-Clusterinspektion vom 18.11.2026

Momentaufnahme vom 18.11.2026, etwa 04:30–06:00 UTC. Die Inspektion selbst war read-only;
es wurden keine Secrets ausgelesen. Die Ergebnisse beschreiben den Prüfzeitraum und sind
keine dauerhafte Verfügbarkeitsgarantie. Hauptbefund: Der Cluster ist im Soll. Behoben
wird mit diesem PR eine Lücke bei den CronJobs: Nach #450 hatte nur `hetzner-import` eine
TTL für abgeschlossene Jobs, dadurch blieb `KubeJobFailed` wegen eines Fehllaufs aktiv.
Neu ist ein Aussetzer am 17.11. 03:44–03:47 UTC (DNS und Garage), der sich selbst erholt hat.

## Soll/Ist-Überblick

| Bereich | Erwarteter Zustand | Beobachtung am 18.11.2026 |
| --- | --- | --- |
| Nodes | Alle Ready ohne Druck | 8/8 Ready (Talos v1.14.4, Kubernetes v1.36.0), keine Pressure-Conditions; CPU 7–25 %, RAM 46–73 % (`cp2` 73 %) |
| ArgoCD | Alle Apps Synced und Healthy | 47/47 Synced/Healthy; `yealink` wieder Healthy (PR #483) |
| Pods | Keine Störungen | Keine Restarts und keine OOM-Kills in 48 h; nur zwei Failed-Jobs in `jitmgmt` vom 17.11. 03:45 UTC |
| Zertifikate | Ready, nicht kurz vor Ablauf | 49 Zertifikate Ready, keine offenen Challenges, keines unter 21 Tagen |
| Persistenter Speicher | Bound Claims, ausreichend Platz | 57/57 PVC Bound (`ceph-rbd`), 52 VolumeAttachments ohne Fehler; keine PVC über 70 % (`vmsingle` 51 %, `mastodon-pg` 36 %) |
| Replikationsslots | Aktiv, kein zurückgehaltenes WAL | 10 Cluster, je 1 aktiver physischer Slot, `reserved`, 0–56 B Rückstand, `.ready` = 0, `max_slot_wal_keep_size` wie gesetzt |
| Backups | Täglich erfolgreich | Alle CNPG-Cluster täglich am 18.11. 02:00–02:55 UTC ok, `mastodon-pg` wöchentlich am 15.11.; keine failed-Backups seit 13.11.; MariaDB-Backups und Offsite-CronJobs aktuell |
| Notifications | Zustellung ohne Fehler | Alertmanager: 8 Mails in 48 h, 0 Fehlschläge, keine Silences |

## Alarme (48 h)

- Aktiv: `KubeJobFailed` (`jitmgmt`, seit 17.11. etwa 04:00 UTC) und `Watchdog`.
- Aufgelöst: Am 16.11. etwa 20:50–21:00 UTC war `vmsingle` kurz nicht erreichbar
  (`AlertingRulesError`/`RecordingRulesError` für etwa 15 Regeln, `TooHighQueryLoad`,
  `TooManyErrorLogs`, `NodeSystemSaturation`; 60 vmalert-Ausführungsfehler). Kurze
  Wiederholung am 17.11. 23:23–23:25 UTC. Ursache offen, der Pod hatte keinen Restart.
- `TooManyLogs` am `vmsingle` flattert zwischen inaktiv und pending (32 Fenster).
- CNPG-Regeln nur pending: 16.11. 07:05 UTC `NoStreamingReplica`/`SlotInactive`
  (`crowdsec-pg-2`, `mastodon-pg-2`), 17.11. 03:45 UTC `WalArchivingStuck` (`goloom`,
  `mastodon`, `paperless`). Kurz pending: `mastodon` am 16.11. 20:55 UTC, `matomo` am
  17.11. 15:25 UTC.
- Grafana auf vizmon01: `proxceph-health-not-ok` und `proxnet-corosync-retransmits`
  firing, `dns-ext-serial-drift` (`jit.land`) pending. Nicht weiter untersucht.

## Vorfall 17.11.2026, 03:44–03:47 UTC

- CoreDNS meldet Upstream-Timeouts (`read udp …->169.254.116.108:53: i/o timeout`).
- Zeitgleich scheitert die WAL-Archivierung gegen Garage `192.168.23.21:3900` mit
  `exit status 4` (`crowdsec`, `goloom`, `mastodon`, `monitoring`, `paperless`,
  `roundcube`).
- Failed-Jobs: `hetzner-import-29914785` (`socket.gaierror`) und `proxmox-sync-29914785`
  (victorianix: `Network is unreachable`).
- Alles hat sich selbst erholt. Weitere Garage-Archivfehler gab es am 13.11. 16–17 UTC und
  am 16.11. gegen 04 UTC.
- Die Ursache (Standortlink oder Upstream-DNS) wurde nicht ermittelt.

## Speicher

- Verzeichnisbelegung gegen kubelet-Metrik: Bei 51 von 52 gemounteten PVCs stimmen `du`,
  kubelet und `df` überein (höchstens 17 MiB Abweichung durch Live-Schreiben bei
  `vmsingle`). `goloom-data` hat keine Shell, dort gilt nur die Metrik (1,3 MiB).
- Es gibt keine lokalen oder hostPath-PVs und keine StorageClass mit `no-provisioner` oder
  `local-path`. hostPath nutzen nur die erwarteten System-DaemonSets sowie `crowdsec-agent`
  (`/var/log`, lesend).
- 63 RBD-Images entsprechen 57 PVs und 6 Snapshot-Images, keine verwaisten.
- 6 VolumeSnapshots: vier alte (Juli/August) und zwei neue
  (`paperless-*-pre-3x-20261113`).
- Verwaiste PVCs unverändert: `authentik` Valkey, `kite-storage`, `wordpress-3` (zwei).
  `jitmgmt-fints` wird vom CronJob `bankabgleich` genutzt und ist kein Befund.
- `/var` der Nodes, frei in GiB (jetzt / vor 7 Tagen):

| Node | jetzt | vor 7 d |
| --- | --- | --- |
| `cp1` | 9,7 | 9,7 |
| `cp2` | 9,5 | 9,6 |
| `cp3` | 9,4 | 9,6 |
| `wrk1` | 22,8 | 7,4 |
| `wrk2` | 13,0 | 19,2 |
| `wrk3` | 21,8 | 21,4 |
| `wrk4` | 11,6 | 11,6 |
| `wrk5` | 12,4 | 18,6 |

  Einordnung: `wrk1` zeigt, dass die Image-GC des Kubelets (Schwelle 85 %, etwa 5,7 GiB
  frei) greift, bevor DiskPressure entsteht. Der Schwund auf `wrk2` und `wrk5` ist
  Image-Churn: beobachten, kein Handlungsbedarf.

## Ceph

- Status `HEALTH_ERR` wegen `AUTH_INSECURE_SERVICE_KEY_TYPE` (16 Service-Entities mit
  `aes`) und `AUTH_INSECURE_SERVICE_TICKETS` (ERR), dazu Warnungen `AUTH_INSECURE_*`.
- Weitere Warnungen: `BLUESTORE_SLOW_OP_ALERT` (`osd.0`, `osd.1`, `osd.8`, `osd.10`),
  `DB_DEVICE_STALLED_READ_ALERT` (`osd.0`), `MDS_CACHE_OVERSIZED` (cloud67, 4 GB bei 2 GB
  Limit) und `noout` (Absicht).
- 9/9 OSDs up/in, Raw 72,7 %, MAX AVAIL 721 GiB, `osd.1` 79,7 %.
- Die Härtung der Ceph-Authentifizierung ist eine offene Entscheidung und nicht Teil dieses PRs.

## Behoben mit diesem PR: TTL für CronJobs

Nach #450 hatte nur `hetzner-import` `ttlSecondsAfterFinished`. Dadurch blieb
`KubeJobFailed` wegen `proxmox-sync-29914785` aktiv und erzeugte alle 12 h Mails. Jetzt
steht `ttlSecondsAfterFinished: 604800` (7 Tage) in elf weiteren CronJobs:

- `jitmgmt`: `proxmox-sync`, `bankabgleich`, `mahnlauf`, `rechnungslauf`, `zertifikatspruefung`
- `jitmgmt-staging`: `rechnungslauf`
- `ciso-assistant-evidence-offsite`, `goloom-backup`, `netbox-media-offsite`,
  `paperless-offsite-backup`, `renovate`

Hinweise:

- Die TTL gilt nur für neue Jobs. Der bestehende Failed-Job `proxmox-sync-29914785` bleibt
  bewusst stehen (Entscheidung Ingo, 18.11.: nicht löschen). `KubeJobFailed` endet erst,
  wenn er aus der History fällt. Der Job `hetzner-import-29914785` verschwindet am 24.11.
  per TTL.
- Logs abgeschlossener `jitmgmt`-Geschäftsjobs bleiben damit nur 7 Tage erhalten
  (bewusst akzeptiert).

## Offene Punkte

- **Ceph:** Auth-Härtung (`AUTH_INSECURE_*`) und Slow-Ops auf `osd.0`.
- **vmsingle:** Aussetzer vom 16. und 17.11., Ursache offen.
- **DNS/Garage:** Ursache der Aussetzer vom 17.11. offen.
- **Dead-Man-Switch:** `Watchdog` an ein externes Ziel leiten (unverändert).
- **Verwaiste PVCs und alte VolumeSnapshots** (unverändert).
- **Offsite-Jobs:** `ciso-assistant-evidence-offsite` und `netbox-media-offsite`
  übertragen 0 Objekte; Quelle leer? Nicht geprüft.
- **`wordpress-3`:** ohne Offsite-Job (unverändert).
- **`ciso-assistant-pg`, `roundcube-pg`:** noch PostgreSQL 17.2.
