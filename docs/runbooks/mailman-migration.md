# Mailman-Migration nach Kubernetes

Umzug der produktiven Mailman-3-Suite von `192.168.2.15` (Docker) in den
Talos/kellerIO-Cluster. Listenadressen und Domains bleiben unverändert.

Stand der Bestandsaufnahme: 28.07.2026

## Ausgangszustand

### Altsystem (192.168.2.15, `/opt/containers/mailman`, docker-compose)

| Komponente | Wert |
|---|---|
| Core | `maxking/mailman-core:latest`, Image-Build **07.04.2021**, GNU Mailman **3.3.4**, alembic `2b73fbcc97c9` |
| Web | `maxking/mailman-web:latest`, Image-Build **07.04.2021**, Django **2.2.20**, HyperKitty **1.3.4**, Postorius **1.3.4** |
| Core-DB | PostgreSQL 16 (Container `mailman-mailman-database-1`), DB `mailman`, 155 MB |
| Web-DB | **SQLite** `web-data/mailmanweb.db`, **5,9 GB**, 73 `django_migrations` |
| Core-Daten | `core/` 58 MB (`var/queue` 17 MB, davon `bad` 15 MB + `shunt` 1,6 MB) |
| Web-Daten | `web-data/` 16 GB: `import-mbox` 6,2 GB, `fulltext_index` 2,3 GB, `.broken`-Index 911 MB, `logs` 41 MB, `static` 11 MB |
| Inhalt | 10 Listen, 309 Members, 288 Adressen, 29 gehaltene Nachrichten, 47 Pendings, 1.564 Django-User |
| Archiv | 41.891 Mails, 33.228 Threads, 17.473 Attachments (4,3 GB Bodies + 1,6 GB Anhänge im DB-Blob) |
| Web-Anpassungen | `settings_local.py`: `LANGUAGE_CODE=de-de`, `MAILMAN_WEB_SOCIAL_AUTH=[]`, SMTP über 192.168.2.209, `no_signup_adapter.py` (Registrierung gesperrt), `DEBUG=True` |

Listen und Archivgrößen:

| Liste | Mails im Archiv |
|---|---|
| `jit-list@jitmail.de` | 24.189 |
| `u22@wohngut.net` | 7.626 |
| `fc@wohngut.net` | 4.490 |
| `talk-ml@binaergewitter.de` | 2.761 |
| `mitglieder@nagomi-dojo-potsdam.de` | 1.456 |
| `krabbelgruppe@jitmail.de` | 1.282 |
| `gruppe@gemeinsam-fuer-halbe.de` | 41 |
| `kulturinfo@halbewelt.de` | 28 |
| `alle@unserabi.de` | 17 |
| `kunden@lists.jitmail.de` | 1 |

### Cluster (Namespace `mailman`, ArgoCD-App `app-mailman`, Synced/Healthy)

| Komponente | Wert |
|---|---|
| Core | `maxking/mailman-core:0.5.2`, GNU Mailman **3.3.10**, alembic `8cc1f79f4459` |
| Web | `maxking/mailman-web:0.5.2`, Django **4.2.16**, HyperKitty **1.3.12**, Postorius **1.3.13**, 99 `django_migrations` |
| DB | CNPG `mailman-pg`, 1 Instanz, PG 16.6, **eine** DB `mailmandb` mit Core- **und** Django-Tabellen, 11 MB, 10 Gi Storage |
| PVCs | `mailman-core-data` 5 Gi (66 MB belegt), `mailman-web-data` 10 Gi (138 MB belegt) |
| LMTP | Service `mailman-lmtp`, LoadBalancer, feste IP **192.168.2.247:8024** |
| Web | Ingress `lists.jitmail.de` HTTP-only auf 192.168.2.246, `/postorius/lists/` liefert 200 |
| Inhalt | **leer** — 0 Listen, 0 Mails |
| Backup | CNPG-ScheduledBackup nach `s3://backups/cnpg-mailman/` (Garage Potsdam) |

### Mailweg heute

```
Internet → MX mx02/mx03 (bzw. mail04 für binaergewitter.de)
        → relay_transport smtp:[mail04.jit-creatives.de]
        → mail04:/etc/postfix/transport_mailman  (111 Zeilen, EMPFÄNGERgenau)
        → smtp:[lists.jitmail.de]:2525
        → 87.191.135.42 (Router Halbe) → 192.168.2.15:25
        → /etc/postfix/transport_mailman → lmtp:[127.0.0.1]:8024
        → mailman-core (Docker)
```

Ausgang: Mailman → `192.168.2.209` (mx02) Port 25, IP-Relay über `mynetworks`.

MX der Listendomains: `unserabi.de`, `wohngut.net`, `jitmail.de`, `lists.jitmail.de`,
`halbewelt.de`, `nagomi-dojo-potsdam.de`, `gemeinsam-fuer-halbe.de` → mx02/mx03.
**Ausnahme `binaergewitter.de` → mail04/mail05.**

### Bereits vorbereitet (verifiziert)

- `mynetworks` auf **mx02 und mx03** enthält `192.168.2.15` **und** `192.168.2.81–86`.
- LMTP `192.168.2.247:8024` ist von **mx02 und mx03** erreichbar; beide bekommen
  `220 GNU Mailman LMTP runner 2.0`.
- rspamd-`sign_networks` (DKIM/ARC) enthält `192.168.2.81–86`; `munge_from` ist
  für `fc@wohngut.net` und `gruppe@gemeinsam-fuer-halbe.de` gesetzt, DKIM-Keys
  und DNS-Records beider Listendomains stimmen überein.

## Zielbild

```
Internet → MX mx02/mx03
        → transport (empfängergenau) → lmtp:[192.168.2.247]:8024
        → mailman-core (Cluster)
```

- Zwei getrennte Datenbanken im CNPG-Cluster: `mailmandb` (Core) und
  `mailmanweb` (Django/HyperKitty) — wie im Altsystem.
- `192.168.2.15` und `mail04` fallen aus dem Listen-Mailpfad heraus.
- Der Alt-Stack bleibt bis zum Point of no Return lauffähig, aber gestoppt.

## Kernproblem: 5 Jahre Versionssprung

Die Altimages sind vom **07.04.2021**. Zwischen Alt und Neu liegen

- Mailman Core **3.3.4 → 3.3.10** (alembic `2b73fbcc97c9` → `8cc1f79f4459`),
- Django **2.2 → 4.2**, HyperKitty **1.3.4 → 1.3.12**, **73 → 99** Django-Migrationen.

**Entscheidung: Migration und Upgrade werden getrennt.** Der Cluster läuft für
den Umzug auf demselben Stand wie `.15`; der Dump geht dann 1:1 hinein, ohne
Schemaanpassung im selben Schritt. Das Upgrade auf 0.5.2 folgt als eigener,
für sich rückrollbarer Vorgang, wenn die Daten nachweislich stehen.

Beide Images sind dafür **per Digest** auf den Stand von `.15` gepinnt:

| Image | Digest | Inhalt |
|---|---|---|
| `maxking/mailman-core` | `sha256:34b5c3af…5a0f199` | Mailman 3.3.4, alembic `2b73fbcc97c9` |
| `maxking/mailman-web` | `sha256:3b240e44…501ff0a0` | Django 2.2.20, HyperKitty 1.3.4, Postorius 1.3.4, 73 Migrationen |

Beide Digests sind der Tag `latest` vom 07.04.2021 — genau das, was auf `.15`
läuft. `latest` wurde von maxking seither nie neu gepusht (aktuell wäre 0.5.2),
ist als Tag aber trotzdem nicht stabil; deshalb Digest statt Tag, und
`# renovate: ignore` an beiden Stellen.

Damit entfällt jede Schemaakrobatik beim Import:

- **Core**: pg_dump der Alt-DB `mailman` → leere `mailmandb`. Gleiche
  alembic-Revision auf beiden Seiten, kein Upgrade beim Start.
- **Web**: der Web-Container legt in der neuen, leeren `mailmanweb` beim ersten
  Start genau die 73 Migrationen an, die die SQLite mitbringt. Der Import ist
  danach reines Datenkopieren.

## Reihenfolge-Zwang

Der Archivimport **muss vor dem Mail-Cutover** stattfinden. Sobald der Cluster
Listenmail annimmt, schreibt HyperKitty dort neue Datensätze; ein nachträglicher
Import von 42.000 Altmails müsste dann gemergt statt geladen werden (ID-Kollisionen).

---

## Phase 0 — GitOps-Vorarbeit — **erledigt am 28.07.2026**

Alle Änderungen liegen in `apps/base/mailman/`. Sie wirken erst mit dem Merge
nach `main` (ArgoCD `app-mailman`: automated, prune, selfHeal).

1. **Images auf den Alt-Stand gepinnt** (`workload.yaml`), siehe Tabelle oben.

2. **Zweite Datenbank** `mailmanweb` als CNPG-`Database`-CR in `database.yaml`
   (CNPG 1.25.0, CRD vorhanden), `encoding: UTF8`,
   **`databaseReclaimPolicy: retain`** — das Löschen des CR darf das Archiv
   nicht mitnehmen. `DATABASE_URL` von `mailman-web` zeigt jetzt dorthin.

3. **CNPG-Storage 10 Gi → 30 Gi** (`database.yaml`). Ceph hat 1,5 TiB frei.
   Bekannter Fallstrick: CNPG-Resize propagiert nicht immer automatisch,
   PVC notfalls direkt patchen.

4. **`mailman-web-data` PVC 10 Gi → 20 Gi** (`workload.yaml`).

5. **`web-settings-configmap.yaml`** neu: `settings_local.py` und
   `no_signup_adapter.py` aus dem Altsystem, per `subPath` ins PVC-Verzeichnis
   gemountet. Übernommen: `LANGUAGE_CODE='de-de'`, `MAILMAN_WEB_SOCIAL_AUTH=[]`,
   Signup-Sperre, SMTP über mx02. **Nicht übernommen: `DEBUG=True`.**

   Zusätzlich enthalten und im Altsystem so nicht nötig:
   **`MAILMAN_ARCHIVER_FROM = ("*",)`**. `settings.py` setzt dafür
   `gethostbyname(MAILMAN_HOSTNAME)`, in Kubernetes also die **ClusterIP** des
   Service `mailman-core` — der Archiver-Request kommt aber von der **Pod-IP**.
   Ohne diese Zeile antwortet HyperKitty mit 403 und archiviert nichts. Die
   Prüfung ist eine reine Stringliste ohne CIDR-Unterstützung, Pod-IPs sind
   dynamisch. Die Authentisierung über `HYPERKITTY_API_KEY` bleibt bestehen,
   der Endpunkt ist ohnehin nur clusterintern erreichbar.

6. **Web-Restarts: Ursache gefunden und behoben.** 37 Neustarts in 9 Tagen mit
   `Completed / Exit 0`. Im Containerlog war nichts zu sehen, weil uwsgi in
   Dateien protokolliert; in `web-data/logs/uwsgi-error.log` stehen 34×
   `SIGINT/SIGTERM received...killing workers`. Die **Liveness lief mit dem
   Default `timeoutSeconds: 1`** gegen eine Django-App mit vereinzelt >10 s
   langen Requests (gemessen bis 16,8 s) bei 2 uwsgi-Workern — 3 Timeouts in
   30 s ergaben SIGTERM, uwsgi fuhr sauber herunter, Exit 0. Das Alt-Image hat
   `processes = 1` und wäre noch anfälliger gewesen.
   Behoben in `workload.yaml` für Core **und** Web: `startupProbe`
   (bis 10 min), entschärfte Readiness, Liveness mit `timeoutSeconds: 10` /
   `failureThreshold: 6`. Wichtig über die Kosmetik hinaus: ohne startupProbe
   könnte die Liveness den Web-Pod **mitten in `manage.py migrate`** abschießen
   und ein halb angewandtes Schema hinterlassen.

7. **Ausgangs-Relay als SPoF notiert** (keine Änderung).
   `SMTP_HOST=192.168.2.209` ist ein einzelner Host; fällt mx02 aus, staut
   ausgehende Listenmail in Mailman. mx03 (`192.168.23.14`) hat dieselben
   `mynetworks`, Mailman kann aber nur einen SMTP-Host. Optional später lösen
   (kleiner Postfix-Relay im Cluster).

### Direkt nach dem Merge auszuführen

Der Rollout der Alt-Images allein reicht nicht: `mailmandb` enthält heute das
**3.3.10**-Schema (alembic `8cc1f79f4459`). Der 3.3.4-Core kennt diese Revision
nicht und startet nicht (`Can't locate revision`). Die DB ist nachweislich leer
(0 Listen, 0 Members, 0 Mails, 1 Admin-User) und wird darum verworfen:

```bash
kubectl -n mailman exec mailman-pg-1 -- psql -U mailman -d mailmandb \
  -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'
kubectl -n mailman rollout restart deploy/mailman-core deploy/mailman-web
```

Das entfernt zugleich die verwaisten Django-Tabellen, die bis jetzt mit im
`mailmandb` lagen — Django zieht ab sofort in `mailmanweb` ein.

**Solange der Core unten ist, wird auch `mailman-web` nicht `Ready`** — das ist
Folge, kein eigener Fehler. Die Probe fragt `/` ab, Kubernetes folgt dem 301 auf
`/postorius/lists/`, und Postorius liefert **503**, weil es die Mailman-REST-API
nicht erreicht. Mit laufendem Core wird die Probe von selbst grün.

Danach prüfen:

```bash
kubectl -n mailman exec mailman-pg-1 -- psql -U mailman -d mailmandb  -tc "select version_num from alembic_version;"   # 2b73fbcc97c9
kubectl -n mailman exec mailman-pg-1 -- psql -U mailman -d mailmanweb -tc "select count(*) from django_migrations;"     # 73
kubectl -n mailman exec deploy/mailman-core -- mailman --version                                                       # 3.3.4
```

Erst wenn diese drei Werte stimmen, passt der Cluster zum Altsystem und der
Import kann beginnen.

## Phase 1 — Probelauf des Imports — **durchgeführt am 28.07.2026**

Gegen Wegwerf-Datenbanken `mailmandb_probe` / `mailmanweb_probe` im selben
CNPG-Cluster; der laufende Stack blieb unangetastet. Ergebnis: **erfolgreich**,
mit vier Befunden, die den echten Import sonst zerrissen hätten.

### Messwerte

| Schritt | Dauer |
|---|---|
| `pg_dump` der Core-DB auf `.15` | wenige Sekunden, 113 KB |
| `pg_restore` der Core-DB | **3,2 s** |
| SQLite 6,26 GB von `.15` holen, gedrosselt auf 12,5 MB/s | **8:11 min** |
| SQLite in den Cluster (`kubectl cp`, ~60 MB/s) | **2:12 min** |
| Datenkopie SQLite → PostgreSQL (99.983 Zeilen) | **403 s**, davon Commit 2,9 s |
| **Summe Datenteil** | **rund 20 min** |

Dazu kommen Indexaufbau und Verifikation. Ein Fenster von **2 h** ist damit
komfortabel bemessen, 1 h wäre knapp, aber machbar.

Zielgröße der Datenbank nach dem Import: **2,7 GB** (aus 6,26 GB SQLite —
PostgreSQL komprimiert Text per TOAST). Spitzenspeicher des PG-Pods: **665Mi**.

### Verifikation

- Core: alembic `2b73fbcc97c9`, 10 Listen, 309 Members, 288 Adressen,
  29 gehaltene Nachrichten, 47 Pendings — **byte-gleich zum Altsystem**.
- Web: **0 Abweichungen** bei den Zeilenzahlen aller 34 Tabellen.
- Anhänge byte-identisch: 17.473 Stück, 1.644.726.656 Bytes, größter 15.069.511.
- Zeitstempel korrekt mit Zeitzone (2009-04-19 bis 2026-07-28).
- Django liest die Daten über das ORM: 41.892 Mails, 10 Listen, 1.564 User,
  Bodies und Anhänge lesbar.

### Befunde

1. **`sqlite3 .backup` auf `.15` ist verboten.** Es liest und schreibt 6 GB auf
   *derselben* Platte (`/dev/sdd1`); Last auf `.15` ging auf 42, auf dem
   PVE-Host `pve.jit.land` (VM 107) auf 60. Abgebrochen. Stattdessen die Datei
   **lesend** streamen (`scp -l 100000`, 12,5 MB/s): Last blieb unter 0,5.
   `/` auf `.15` hat ohnehin nur 5,5 G frei — die Kopie passt dort gar nicht.
2. **Der PG-Pod wurde OOMKilled** (Exit 137) beim Laden von
   `hyperkitty_attachment`; der Client sah nur `SSL SYSCALL error: EOF detected`.
   Das Limit von 512Mi war am Betriebswert (~185Mi) bemessen, nicht am Import.
   Behoben (PR #65): Limit 2Gi, Requests unverändert. Gemessene Spitze danach
   665Mi.
3. **NUL-Bytes.** 21 Werte in `hyperkitty_email.content` enthalten `0x00` (SAP-
   Ausdrucke auf `jit-list`). PostgreSQL kann das in `text`/`varchar`
   grundsätzlich nicht speichern. Der Loader entfernt sie und **zählt sie im
   Protokoll mit**, damit die Änderung nicht still passiert.
4. **Eine Live-Kopie der SQLite ist nicht konsistent** — `PRAGMA
   integrity_check` meldete 64 Fehler, aber **ausschließlich** in
   `sqlite_autoindex_django_q_task_1`, der ständig beschriebenen Taskqueue. Das
   Archiv war unversehrt. In Phase 2 ist der Stack ohnehin gestoppt.
   `django_q_ormq` und `django_q_schedule` sind in der Quelle **leer**,
   `django_q_task` enthält nur alte Ergebnisse ⇒ alle drei werden übersprungen.

### Werkzeug-Fallstricke

- `pg_restore` im 2021er-Image ist zu alt für PG-16-Dumps
  (`unsupported version (1.15)`) ⇒ Restore im CNPG-Pod ausführen.
- **`ssh … | kubectl exec -i` überträgt nichts** (leere Datei), und roher
  Stdin-Pipe bricht bei großen Dateien ab (`connection reset by peer` nach
  32 KB). `kubectl cp` funktioniert dagegen zuverlässig und schnell.
- Ein Patch der ArgoCD-`Application` (etwa `automated` entfernen, um die Pods
  herunterzufahren) ist **wirkungslos**: das App-of-Apps stellt sie sofort
  wieder her. Wer die Pods wirklich anhalten muss, ändert `replicas` in Git.

### Ablauf (für die Wiederholung in Phase 2)

Ziel: Dauer messen und die Schemakette einmal fehlerfrei durchspielen, ohne
das Altsystem anzufassen.

1. Konsistente Kopien ziehen (Altsystem läuft weiter):

   ```bash
   ssh root@192.168.2.15 'docker exec mailman-mailman-database-1 \
     pg_dump -U mailman -Fc mailman > /root/mailman-core-probe.dump'
   ssh root@192.168.2.15 'sqlite3 /opt/containers/mailman/web-data/mailmanweb.db \
     ".backup /root/mailmanweb-probe.db"'
   ```

   Platzbedarf auf `.15` prüfen — die Kopie ist 5,9 GB groß.

2. Hilfs-Pod mit eigenem PVC (≥ 10 Gi) im Namespace `mailman` starten, Dateien
   streamen:

   ```bash
   ssh root@192.168.2.15 'cat /root/mailmanweb-probe.db' \
     | kubectl -n mailman exec -i migrate-helper -- tee /data/mailmanweb.db >/dev/null
   ```

3. Alt-Schema erzeugen, Daten laden, nach vorne migrieren (Details in Phase 2).

4. **Messen**: Dauer pgloader, Dauer Indexaufbau, resultierende DB-Größe.
   Diese Zahlen bestimmen das Wartungsfenster.

5. Testdaten anschließend wieder wegwerfen (`Database`-CR neu, PVC leeren).

## Phase 2 — Freeze und echter Import

**Wartungsfenster.** Während des Freeze nimmt niemand Listenmail an; mx02/mx03
und mail04 stellen zurück (deferred, kein Verlust). Fenster nach den Messwerten
aus Phase 1 ansetzen, Richtwert 2–3 h.

1. **Alt-Stack einfrieren**, Queue vorher leerlaufen lassen:

   ```bash
   ssh root@192.168.2.15 'mailq | tail -1; \
     find /opt/containers/mailman/core/var/queue/{in,pipeline,out,retry,virgin,bounces} -type f | wc -l'
   ssh root@192.168.2.15 'docker stop mailman-web mailman-core'
   ```

   `bad` (15 MB) und `shunt` (1,6 MB) werden **nicht** migriert.

   **Auch den Cluster-Stack anhalten** — und zwar über Git, nicht über
   `kubectl scale`. `pg_restore` hängt sonst an Locks, solange `mailman-core`
   mit der Datenbank verbunden ist (im Probelauf reproduziert: 2 min ohne
   Fortschritt). Ein `kubectl scale` wird von ArgoCD binnen Sekunden
   zurückgedreht, und ein Patch an der `Application` ebenso, weil sie aus dem
   App-of-Apps kommt — beides am 28.07. verifiziert.

   Dafür liegt der **Wartungsschalter** bereit:
   `apps/overlays/main/mailman/maintenance-scale-to-zero.yaml`, eingebunden über
   die `patches`-Liste des Overlays. Branch `ops/mailman-maintenance-freeze`
   (Draft-PR) enthält ihn aktiviert.

   ```bash
   # anhalten
   gh pr ready <PR>; gh pr merge <PR> --merge
   kubectl -n argocd annotate application app-mailman \
     argocd.argoproj.io/refresh=normal --overwrite      # Sync sofort statt in ~3 min
   kubectl -n mailman rollout status deploy/mailman-core --timeout=120s
   kubectl -n mailman get pods            # nur noch mailman-pg-1 darf laufen
   ```

   **Nach dem Import unbedingt revertieren**, sonst bleibt Mailman unten:

   ```bash
   gh pr create --base main --title "Revert: Wartungsschalter Mailman" ...   # oder
   git revert <merge-commit> && git push
   kubectl -n argocd annotate application app-mailman \
     argocd.argoproj.io/refresh=normal --overwrite
   ```

   Achtung bei der Reihenfolge: der Message-Store aus Schritt 4 wird per
   `kubectl cp` in den **laufenden** Core-Pod kopiert. Entweder erst nach dem
   Revert, oder vor dem Anhalten — der Schritt ist idempotent, beides geht.

2. **Dumps ziehen** (wie Phase 1, ohne `-probe`), Prüfsummen notieren.

3. **Core-DB einspielen**: `mailmandb` leeren, Dump als Rolle `mailman`
   restoren, dann `mailman-core` starten. Quelle und Ziel stehen beide auf
   alembic `2b73fbcc97c9`, es findet **kein** Schema-Upgrade statt. Danach:

   ```bash
   kubectl -n mailman exec deploy/mailman-core -- mailman --run-as-root lists
   ```

   Erwartung: **10 Listen**, identisch zur Liste oben.

4. **Core-Dateien nachziehen.** Members und Listen stehen in der Datenbank; auf
   der Platte liegen nur zwei Dinge, die zählen — **zusammen rund 2 MB**
   (am 28.07. inventarisiert und am 29.07. erprobt):

   | Verzeichnis | Inhalt | Übernehmen |
   |---|---|---|
   | `var/messages/` | 30 Dateien, 1,6 MB — Mailmans Message-Store, Pfad ist der Message-ID-Hash (`messages/C7/SS/C7SSZ…`) | **ja, zwingend** |
   | `var/lists/` | 4 Dateien, 412 K — ausschliesslich `digest.mmdf`: angesammelte, noch nicht versandte Digests (jit-list, talk-ml, mitglieder) | ja |
   | `var/data/` | `postfix_domains`, `postfix_lmtp` — von Mailman **erzeugte** MTA-Maps mit den ALTEN Transportwegen | nein |
   | `var/templates/`, `var/archives/`, `var/cache/` | **komplett leer, 0 Dateien** | entfällt |
   | `var/etc/mailman.cfg` | vom Image aus Env erzeugt | **nein, niemals** |
   | `var/logs/` (41 M), `var/queue/` (562 Dateien, davon 15 M `bad` + 1,6 M `shunt`), `var/locks/`, `var/master.pid` | Laufzeit und Dead Letters | nein |

   **Warum `messages/` zwingend ist:** die Tabelle `message` hat 30 Zeilen, im
   Store liegen exakt 30 Dateien — 1:1. **15 davon sind gehaltene
   Moderationsanfragen.** Die Datenbank speichert nur den Hash, der Text liegt
   allein als Datei vor. Ohne den Baum wirft Mailman beim Zugriff einen
   `FileNotFoundError` — die Moderationsansicht bleibt also nicht bloss leer,
   sie bricht ab.

   ```bash
   POD=$(kubectl -n mailman get pod -l app.kubernetes.io/name=mailman-core \
           -o jsonpath='{.items[0].metadata.name}')

   ssh root@192.168.2.15 'cd /opt/containers/mailman/core/var && \
     tar czf /tmp/mm-var.tgz messages lists'
   scp root@192.168.2.15:/tmp/mm-var.tgz /tmp/
   kubectl -n mailman cp /tmp/mm-var.tgz mailman/$POD:/tmp/mm-var.tgz
   kubectl -n mailman exec $POD -- sh -c 'cd /opt/mailman/var && \
     tar xzf /tmp/mm-var.tgz && chown -R 100:65533 messages lists && \
     rm -f /tmp/mm-var.tgz'
   ```

   Das `chown` ist nötig: `uid 100` ist auf beiden Seiten `mailman`, auf `.15`
   gehört aber alles `100:0`, während der Container als `gid 65533 (nogroup)`
   läuft. Der Schritt ist **idempotent** — der Store ist inhaltsadressiert, der
   Pfad *ist* der Hash — und lässt sich vor wie nach dem DB-Restore ausführen;
   nötig ist nur ein laufender Core-Pod als Ziel.

   Gegenprobe (am 29.07. mit **14 von 14** erfolgreich durchgeführt):

   ```bash
   printf '%s\n' "exec('''
   from zope.component import getUtility
   from mailman.interfaces.messages import IMessageStore
   from mailman.interfaces.requests import IListRequests, RequestType
   from mailman.interfaces.listmanager import IListManager
   store = getUtility(IMessageStore)
   ok = 0
   fail = 0
   for lst in getUtility(IListManager).mailing_lists:
       for r in list(IListRequests(lst).of_type(RequestType.held_message)):
           try:
               m = store.get_message_by_id(r.key)
               if m is None:
                   raise KeyError(\"None\")
               ok = ok + 1
           except Exception as e:
               fail = fail + 1
               print(\"FEHLT:\", lst.list_id, r.key)
   print(\"BILANZ: aufloesbar=%d nicht_aufloesbar=%d\" % (ok, fail))
   ''')" | kubectl -n mailman exec -i deploy/mailman-core -- mailman shell
   ```

   Zwei Fallstricke dabei: `mailman shell` verdaut aus der Pipe **keine
   mehrzeiligen Blöcke** (der REPL bricht mit `SyntaxError` ab), deshalb der
   Umweg über ein einzelnes `exec('''…''')`. Und bei gehaltenen Nachrichten ist
   `r.key` die **Message-ID**, nicht der Hash — es braucht
   `get_message_by_id()`, nicht `get_message_by_hash()`, sonst meldet die
   Prüfung falsche Fehlschläge.

5. **Web-Schema prüfen.** Es ist bereits da: `mailman-web` läuft auf dem
   Alt-Image und hat `mailmanweb` beim ersten Start angelegt. Gegenprobe vor
   dem Kopieren — die Zahl muss der SQLite entsprechen:

   ```sql
   select count(*) from django_migrations;   -- muss 73 sein
   ```

   Vor dem Import `mailman-web` auf 0 Replicas skalieren, damit während des
   Ladens niemand in die Tabellen schreibt (ArgoCD selfHeal beachten: dafür
   die App kurz auf `syncPolicy: {}` setzen oder mit
   `argocd app set --sync-policy none` arbeiten).

6. **Daten kopieren** mit `apps/base/mailman/migration-sqlite-to-postgres.py`
   im Helper-Pod (nutzt das `mailman-web`-Image, bringt psycopg2 und das
   `sqlite3`-Modul mit):

   ```bash
   SQLITE_PATH=/data/mailmanweb.db \
   PG_DSN='host=mailman-pg-rw port=5432 dbname=mailmanweb user=mailman password=…' \
   python3 /data/migration-sqlite-to-postgres.py
   ```

   **Kein pgloader.** Das Zielschema legt Django korrekt an; pgloader würde die
   Typen aus SQLites dynamischer Typisierung neu raten — genau der Fehler aus
   der Roundcube-Migration (siehe `docs/learnings/`). Das Skript castet
   stattdessen anhand des PG-Spaltentyps (bool aus 0/1, Zeitstempel aus
   Textform, bytea) und begrenzt Batches nach **Bytes** statt Zeilen.

   Es braucht **keinen Superuser**: alles läuft in *einer* Transaktion mit
   `SET CONSTRAINTS ALL DEFERRED`. Djangos Fremdschlüssel sind
   `DEFERRABLE INITIALLY DEFERRED` (geprüft: 39/39), damit ist die
   Ladereihenfolge egal und `enableSuperuserAccess` bleibt aus. Nebeneffekt:
   ein Abbruch rollt vollständig zurück, es bleiben nie Teildaten liegen —
   im Probelauf zweimal bestätigt.

   Gegenprobe nach dem Lauf:

   ```sql
   select count(*) from hyperkitty_email;       -- 41891
   select count(*) from hyperkitty_thread;      -- 33228
   select count(*) from hyperkitty_attachment;  -- 17473
   select count(*) from auth_user;              -- 1564
   ```

7. **`mailman-web` wieder hochfahren** (Alt-Image, keine Versionsänderung).
   Es darf **keine** Migration mehr laufen — der Stand ist auf beiden Seiten 73:

   ```sql
   select count(*) from django_migrations;   -- weiterhin 73
   ```

   Erscheint hier trotzdem `Running migrations` mit angewandten Schritten, ist
   etwas an der Image-Pinnung vorbeigelaufen: abbrechen und klären.

8. **Volltextindex neu bauen** (der alte Whoosh-Index wird nicht übernommen):

   ```bash
   kubectl -n mailman exec deploy/mailman-web -- django-admin rebuild_index --noinput
   ```

   Läuft lange und ist nicht cutover-kritisch — kann nach dem Cutover laufen,
   solange klar ist, dass die Archivsuche bis dahin unvollständig ist.

9. **Sofort-Backup** ziehen, bevor Mail fließt:

   ```bash
   kubectl -n mailman create -f - <<'EOF'
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata: { generateName: mailman-post-import-, namespace: mailman }
   spec: { cluster: { name: mailman-pg } }
   EOF
   ```

## Phase 3 — Verifikation vor dem Cutover

Ohne echten Mailfluss prüfbar:

- 10 Listen, Mitgliederzahlen je Liste gegen das Altsystem.
- 29 gehaltene Nachrichten und 47 Pendings in Postorius sichtbar.
- Login als bestehender Django-User; Archiv einer großen Liste (`jit-list`)
  und einer kleinen (`kulturinfo`) öffnet, Threads und Anhänge laden.
- `mailman-core` REST erreichbar, `mailman-web` ohne Neustart über ≥ 1 h.
- Testliste anlegen, von extern über mx02 einliefern, Rundlauf prüfen —
  über die LMTP-IP, **bevor** produktive Domains umgestellt werden:

  ```bash
  ssh root@192.168.2.209 'swaks --server 192.168.2.247 --port 8024 --protocol LMTP \
    --to test@lists.jitmail.de --from postmaster@jitcreatives.de'
  ```

## Phase 4 — Mail-Cutover A — **vollzogen am 29.07.2026**

Sicherung der alten Map liegt auf `.15` unter
`/root/transport_mailman.bak-20260729-183245`.

**Verifiziert, in dieser Reihenfolge:**

1. Negativtest — `gibtesnicht@wohngut.net` über den vollen Weg: Postfix routet
   nach `192.168.2.247:8024`, der Cluster antwortet
   `550 Requested action not taken: mailbox unavailable`. Der Transport greift,
   und Unbekanntes wird sauber abgelehnt.
2. Positivtest — `kunden-request@lists.jitmail.de` mit `help`: `status=sent
   (250 Ok)`. Ein `-request`-Kommando antwortet nur dem Absender und behelligt
   keine Mitglieder; das ist der richtige Test für einen Cutover.
3. Ausgang — die Antwort verließ den Cluster von **192.168.2.84** (Talos-Node)
   über mx02 und wurde von mail04 mit `250 2.0.0 Ok` angenommen.
4. Signatur — spam01 zeigt für diese Nachricht
   `DKIM_SIGNED{jitmail.de:s=2023}` **und** `ARC_SIGNED{jitmail.de:s=2023:i=1}`.
   Die `sign_networks`-Vorarbeit für die Node-IPs greift also.

**⚠️ Dabei aufgetreten: der LMTP-Runner startet nicht immer mit.** Direkt nach
dem Cutover lief jede Mail in `connect to 192.168.2.247:8024: Connection
refused`. Ursache im Core-Log:

```
TimeoutError: SMTP server started, but not responding within allotted time.
Try increasing the `ready_timeout` parameter.
```

Das ist aiosmtpds Selbsttest nach dem Binden, der zu früh aufgibt. Der Prozess
war tot, **Port 8001 lief aber weiter — der Pod galt als gesund**, während der
Maileingang stand. Ein `kubectl rollout restart deploy/mailman-core` hat es
behoben.

Konsequenz: die Probes prüfen seither **beide** Ports (exec statt tcpSocket,
siehe `workload.yaml`), damit ein toter LMTP-Runner einen Neustart auslöst
statt unsichtbar zu bleiben. Tritt der Fehler häufiger auf, ist der nächste
Schritt `ready_timeout` in einer `mailman-extra.cfg` hochzusetzen.

Nur **eine** Datei ändert sich; der komplette Weg davor bleibt bestehen.

Auf `192.168.2.15`, `/etc/postfix/transport_mailman`: alle acht Zeilen von
`lmtp:[127.0.0.1]:8024` auf `lmtp:[192.168.2.247]:8024` ändern, dann

```bash
postmap /etc/postfix/transport_mailman && postfix reload
```

Rollback = Datei zurück, `postmap`, `reload`, Alt-Container wieder starten.
Dauer unter einer Minute.

**Prüfen nach dem Cutover:**

- Zustellung je Liste (eine Testmail pro Domain).
- Auf spam01/spam02: `DKIM_SIGNED` **und** `ARC_SIGNED` mit einer Node-IP
  `192.168.2.81–86` als Client — nicht mehr `192.168.2.15`.
- Ausgang: Mailman → mx02:25 wird über `mynetworks` akzeptiert.
- Bounces (`*-bounces@`) laufen über denselben Weg zurück.

## Phase 5 — Web-Cutover

`lists.jitmail.de` ist CNAME auf `jitmail.de` → `87.191.135.42`; bis zum
Router-Cutover terminiert der Traefik auf `.15` weiterhin das öffentliche TLS.

File-Router in `/opt/containers/traefik/data/dynamic_conf.yml` ergänzen, Muster
wie `wordpress_halbe_k8s_router` (Priority 1000 schlägt die Docker-Labels),
Service → `192.168.2.246`. Der Cluster-Ingress liefert unter
`Host: lists.jitmail.de` HTTP 200 auf `/postorius/lists/` und besitzt bereits
ein cert-manager-TLS-Secret für den direkten `.246`-Pfad.

`nginx.org/ssl-redirect` und `nginx.org/redirect-to-https` bleiben bis zum
Router-Cutover `false`. So kann cert-manager das Zertifikat vorab ausstellen,
ohne den HTTP-Upstream des Traefik in einen Redirect-Loop zu schicken.

## Phase 6 — Mail-Cutover B (Altpfad entfernen)

Erst nach einigen stabilen Tagen.

1. Die 111 empfängergenauen Zeilen aus `mail04:/etc/postfix/transport_mailman`
   nach **mx02 und mx03** übernehmen, dort mit Ziel `lmtp:[192.168.2.247]:8024`.
   Domainweite Einträge sind **nicht** möglich: `jitmail.de` und
   `jit-creatives.de` haben neben Listen auch normale Postfächer auf mail04.
2. Prüfen, dass `reject_unverified_recipient` auf den Gateways mit dem
   LMTP-Ziel funktioniert — die Adressverifikation probt dann gegen Mailman
   statt gegen mail04. Vorher mit einer nicht existierenden Listenadresse testen.
3. `binaergewitter.de` hat noch MX auf mail04/mail05. Entweder MX auf mx02/mx03
   umstellen (steht ohnehin auf der MX-Migrationsliste) oder `talk-ml` bis dahin
   über den `.15`-Relay laufen lassen. mail04 (88.198.107.12) kann
   `192.168.2.247` nicht erreichen — ein direkter Transport von dort ist ausgeschlossen.
4. Danach: Einträge auf mail04 entfernen, Portweiterleitung 2525 am Router
   Halbe abbauen, Postfix-Relay-Rolle von `.15` entfernen.
5. `192.168.2.15` aus `mx_gateway_trusted_clients`
   (`cfgmgmt01:/etc/ansible/group_vars/mx_gateways.yml`) **und** aus
   `sign_networks` der rspamd-Rolle streichen — erst wenn `.15` wirklich keine
   Listenmail mehr einliefert.

## Phase 7 — Versions-Upgrade (eigener Vorgang)

Bewusst **nach** der Migration und getrennt davon. Erst wenn der Cluster
Listenmail stabil verarbeitet und ein verifiziertes Backup existiert.

1. Frisches CNPG-Backup, und die Alt-Images bleiben als Rückfallebene im
   Repo dokumentiert.
2. Images auf `maxking/mailman-core:0.5.2` und `maxking/mailman-web:0.5.2`
   heben, `# renovate: ignore` wieder durch die `renovate:`-Marker ersetzen.
3. Beim Start laufen dann **automatisch**: alembic `2b73fbcc97c9` →
   `8cc1f79f4459` im Core und `django-admin migrate` 73 → 99 im Web.
   Die `startupProbe` (10 min) deckt das ab.
4. Danach `select count(*) from django_migrations` = **99** und
   `mailman --version` = **3.3.10**.
5. Volltextindex nach dem HyperKitty-Sprung 1.3.4 → 1.3.12 neu bauen.

Rollback ist hier nur über das Backup möglich — Django- und alembic-Migrationen
laufen nicht rückwärts. Deshalb nicht mit dem Umzug vermischen.

## Phase 8 — Nacharbeiten

- **jitix-Automation**: `jitmgmt/customer/jitix_remote.py:142-143` schreibt die
  Transport-Stanzas nach mail04/mail05. Muss auf mx02/mx03 zeigen, sonst fehlen
  neu angelegten Listen die Transporteinträge.
- **Alt-Stack abbauen**: Container stoppen und deaktivieren, Verzeichnis
  `/opt/containers/mailman` archivieren. `import-mbox` (6,2 GB),
  `fulltext_index.broken-*` (911 MB) und `fulltext_index.aborted-*` sind
  Wegwerfdaten; die Roh-mboxen ggf. einmal offsite sichern und dann löschen.
- **Backup verifizieren**: Restore der `mailmanweb` aus dem Garage-S3-Backup
  in eine Wegwerf-DB einmal durchspielen (Runbook `backup-restore.md`).
- **TLS direkt im Cluster**: Zertifikat und Issuer sind vorbereitet. Vor dem
  Routerwechsel Secret/SNI prüfen; Redirects zusammen mit dem allgemeinen
  Traefik-Cutover aktivieren.
- **Image-Pinning**: `maxking/mailman-*:0.5.2` steht im Repo, Renovate ist
  konfiguriert. Ein Upgrade **nicht** mit der Migration vermischen.

## Rollback

| Phase | Rollback | Aufwand |
|---|---|---|
| 0–3 | GitOps-Änderungen zurücknehmen, Alt-Stack läuft durchgehend | trivial |
| 4 | `transport_mailman` auf `.15` zurück + `postmap`/`reload`, Alt-Container starten | < 1 min |
| 5 | Traefik-File-Router entfernen | < 1 min |
| 6 | Transport auf den Gateways entfernen, Weg über `.15` wieder aktiv | Minuten |
| 7 | nur über das Backup — Migrationen laufen nicht rückwärts | Restore |

**Point of no Return** ist der erste produktive Maileingang im Cluster
(Phase 4). Ab da divergieren Archiv und Mitgliederstand. Ein Rollback nach
mehr als wenigen Stunden bedeutet Datenverlust im Cluster oder einen
Rückwärts-Merge. Das ist explizit zu entscheiden, nicht implizit auszusitzen.

## Risiken

| Risiko | Bewertung |
|---|---|
| Django 2.2.20 gegen PostgreSQL 16.6 | im Probelauf 28.07. bestätigt: Schema, Migrationen und ORM-Zugriff funktionieren |
| Django-Migrationen 2.2 → 4.2 scheitern an Altdaten | aus der Migration herausgezogen, jetzt Phase 7 mit eigenem Backup davor |
| Import belastet `.15` bis zur Unbrauchbarkeit | erledigt: nur noch lesender, gedrosselter Stream statt lokaler Kopie |
| CNPG-Storage zu klein für das Archiv | erledigt: 10 Gi → 30 Gi |
| `mailman-web` startet sich regelmäßig neu (37× in 9 d) | erledigt: Liveness-Timeout war die Ursache, startupProbe ergänzt |
| `uwsgi.log` wuchs in 15 Tagen auf 110 MB im PVC (Gatus pollt alle 5 s, uwsgi rotiert nicht) | mit 20 Gi vorerst unkritisch, langfristig Housekeeping nötig |
| Ausgang hängt allein an mx02 | akzeptiert, Fallback offen |
| Adressverifikation der Gateways gegen LMTP | erst in Phase 6 relevant, dort explizit testen |
| `binaergewitter.de` MX noch auf mail04 | blockiert Phase 6 für diese Liste |
