# Mailman: Volltextindex nach Datenmenge statt Mailanzahl planen

## Kontext

Beim Upgrade von Mailman Web auf `maxking/mailman-web` 0.5.2 musste der
HyperKitty-Volltextindex am 31.07.2026 neu aufgebaut werden. Die Datenbank
enthielt 41.925 Mails mit insgesamt rund 4,3 GiB Mailtext. Der alte Whoosh-Index
war unvollstaendig beziehungsweise nicht mehr verlaesslich; breite Suchanfragen
liefen in Timeouts und brachten den Web-Pod auch mit 2 GiB Limit zum OOM.

Der scheinbar kleine Bestand von rund 42.000 Zeilen ist fuer einen
Volltextindex kein kleiner Bestand. Entscheidend sind Textmenge, Tokenanzahl und
Groesse einzelner Dokumente, nicht die Zahl der Mails:

| Messwert | Wert |
|---|---:|
| Mails | 41.925 |
| Mailtext | rund 4,3 GiB |
| Groesste Mail | 27.547.710 Byte |
| IDs 1-10.482 | 107 MiB |
| IDs 10.483-20.963 | 770 MiB |
| IDs 20.964-31.444 | 3.268 MiB |
| IDs 31.445-41.925 | 191 MiB |

Vor allem automatisch erzeugte taegliche Systemberichte liegen konzentriert in
einem ID-Bereich und sind jeweils mehrere MiB gross. Gleich grosse ID-Bereiche
sind deshalb extrem ungleich teure Index-Shards.

## Fehlversuche und Auswirkungen

1. `django-admin rebuild_index --noinput` gegen den Index auf Ceph RBD war zu
   langsam und nicht ausreichend kontrollierbar. Ein Aufbau direkt im
   produktiven Web-PVC ist ausserdem unnoetig riskant, weil ein Abbruch einen
   partiellen aktiven Index hinterlassen kann.
2. Ein einzelner Worker baute auf lokalem `emptyDir` mit Batches von 1.000 Mails.
   Er erreichte nach rund zwei Stunden erst ID 17.000. Einzelne Batches wurden
   mit wachsendem Index immer langsamer.
3. Vier parallele, nach Mailanzahl geteilte Shards liefen ebenfalls mit
   1.000er-Batches. Zwei Shards waren schnell fertig, waehrend der 3,2-GiB-
   Bereich weit zurueckblieb. Der Pod durfte bis 6 GiB belegen, lief aber auf
   einem 8-GiB-Node, auf dem bereits rund 4,5 GiB genutzt wurden. Der Kernel
   meldete `SystemOOM`, `python3` wurde beendet und der Node war kurz
   `NotReady`. Dadurch waren auch ArgoCD, Ceph CSI und weitere Workloads auf
   diesem Node gestoert.
4. Die bis dahin fertigen lokalen Shards lagen nur im `emptyDir` des
   fehlgeschlagenen Pods und waren nach dessen Loeschung verloren. Ein hohes
   Containerlimit ist kein Ersatz fuer freie physische Node-Kapazitaet und
   persistente Checkpoints.

Der produktive Mailfluss blieb aktiv, weil nur `mailman-web` auf null skaliert
war. `mailman-core`, LMTP und PostgreSQL liefen weiter. Der produktive Index
wurde von den fehlgeschlagenen Staging-Jobs nicht veraendert.

## Technische Ursache

HyperKitty nutzt ueber Django Haystack standardmaessig
`haystack.backends.whoosh_backend.WhooshEngine`. Whoosh 2.7.4 ist eine
Pure-Python-Suchengine. Haystacks `WhooshSearchBackend.update()` erzeugt pro
Aufruf einen `AsyncWriter` und fuehrt am Ende immer `writer.commit()` aus.
Viele kleine `backend.update()`-Aufrufe begrenzen zwar den Spitzenspeicher,
erzeugen aber viele Segmente und wiederholte Commit-/Merge-Arbeit. Sehr grosse
Batches reduzieren die Commitanzahl, vervielfachen bei grossen Mails jedoch den
Speicherbedarf waehrend Aufbereitung und Tokenisierung.

Die drei gekoppelten Engpaesse sind damit:

- CPU fuer Python-Tokenisierung,
- RAM proportional zur Textmenge eines gleichzeitig vorbereiteten Batches,
- zufaellige und metadatenlastige I/O beim Schreiben und Mergen der
  Whoosh-Segmente.

Eine Zeilenanzahl ist fuer Ressourcenplanung und Sharding ungeeignet. Batches
und Shards muessen nach `octet_length(content)` begrenzt werden.

## Sicheres Verfahren mit Whoosh

Wenn Whoosh beibehalten wird, gilt fuer einen Vollaufbau:

1. Web per GitOps auf null skalieren; Core und LMTP duerfen weiterlaufen.
2. Vorher CNPG-Backup und Snapshot des Web-PVC verifizieren.
3. Nie direkt in `fulltext_index` schreiben. Auf lokalem Scratch-Speicher oder
   einem Staging-PVC bauen und den produktiven Pfad erst nach der Pruefung
   atomar ersetzen.
4. Einen dedizierten Node mit real freiem RAM verwenden. Requests, Limits und
   aktuelle Node-Belegung gemeinsam pruefen; die Summe moeglicher Limits darf
   keinen System-OOM ausloesen.
5. Shards nach Textbytes statt IDs oder Mailanzahl bilden. Fuer diesen Bestand
   ergaben acht zusammenhaengende Bereiche jeweils rund 540 MiB Quelltext.
6. Innerhalb der Shards Batches sowohl nach Bytes als auch nach maximaler
   Dokumentanzahl begrenzen. Der korrigierte Lauf verwendet rund 25 MiB und
   hoechstens 500 Mails pro Commit.
7. Fertige Shards persistent checkpointen. Bei einem Neustart nur ab der
   letzten erfolgreich committed Mail fortsetzen.
8. Shards lokal mergen, dann den fertigen Index ins Staging kopieren.
9. Nicht nur `doc_count()` pruefen. Die Menge der gespeicherten `django_id`
   muss exakt den IDs in `hyperkitty_email` entsprechen.
10. Erst danach den Staging-Index in das produktive PVC kopieren, den alten
    Index als datierte Rueckfallkopie behalten und per Rename umschalten.

Ein noch schnellerer Whoosh-Builder sollte Haystacks Dokumentaufbereitung
verwenden, aber pro Shard einen langlebigen Writer offenhalten und nur einmal
committen. Das vermeidet die wiederholte Segmentarbeit von
`WhooshSearchBackend.update()`. Diese Variante muss vor Produktion gegen den
Standard-Builder auf Dokumentvollstaendigkeit und identische Suchtreffer
getestet werden.

## Uebergrosse Mailtexte im Index begrenzen

Der groesste Hebel liegt vor dem Suchbackend. HyperKittys
`email_text.txt` uebergibt den vollstaendigen Wert von `object.content` an den
Filter `nolongterms`. Damit werden auch mehrmegabytegrosse Systemberichte
vollstaendig durch Djangos Template-Auswertung und Haystacks
`full_prepare()` geschickt.

Eine Begrenzung gilt nur fuer den Suchindex; Mailtext und Anzeige im Archiv
bleiben unveraendert. Fuer den produktiven Bestand ergeben sich:

| Indexlimit pro Mail | Betroffene Mails | Zu indexierender Mailtext |
|---|---:|---:|
| keines | 0 | 4.335 MiB |
| 2 MiB | 521 | 3.598 MiB |
| 1 MiB | 1.054 | 2.860 MiB |
| 256 KiB | 3.821 | 1.460 MiB |

Ein Limit von 1 MiB entfernt also rund ein Drittel des zu tokenisierenden
Textes und deckelt den schlimmsten Einzelfall von 27,5 MiB. Nachteil: Begriffe,
die in einer uebergrossen Mail erst hinter dem Limit stehen, sind nicht mehr
auffindbar. Betreff, Absender, Tags, Datum, Attachment-Namen und der erste Teil
des Bodys bleiben suchbar.

Vor einer produktiven Aenderung auf einer Restore-Kopie mit einem
ueberschriebenen Haystack-Template benchmarken und fachlich entscheiden, ob
1 MiB oder 256 KiB ausreichen. Ein Limit ist fuer diesen Bestand
voraussichtlich wirksamer als ein reiner Storage-Wechsel.

## NFS und CephFS

Ein Netzwerkdateisystem ist technisch als Staging-Speicher moeglich, aber kein
automatischer Beschleuniger:

- Whoosh erzeugt viele kleine Dateien, Metadatenoperationen, Locks und atomare
  Renames. Ein entferntes Dateisystem hat dabei meist mehr Latenz als lokales
  SSD-Scratch und kann den Aufbau verlangsamen.
- Locking und Rename-Semantik muessen mit dem konkreten NFS-/CephFS-Client unter
  Pod- und Node-Neustarts getestet werden. Ein nur scheinbar gemountetes RWX-PVC
  ist kein belastbarer Checkpoint.
- Der Cluster hat aktuell die StorageClasses `ceph-rbd` und `ceph-fs`, aber
  keine NFS-StorageClass. `ceph-fs` kann die Rolle eines RWX-Staging-Volumes
  uebernehmen.
- Sinnvoll ist: aktive Shards auf lokalem SSD-Scratch bauen, jeden fertigen
  Shard als Checkpoint auf CephFS/NFS kopieren und den validierten Endindex als
  Artefakt dort ablegen. Direkt auf NFS/CephFS zu indexieren ist erst nach einem
  Benchmark sinnvoll.

Worker 4 ist wegen `storage=hdd:PreferNoSchedule` zwar frei, aber sein lokales
Scratch liegt nicht auf dem schnellsten Medium. Fuer planbare Vollaufbauten ist
ein dedizierter Worker oder eine temporaere VM mit lokaler SSD/NVMe und genug
RAM die bessere Ausfuehrungsumgebung. Der fertige Index kann anschliessend als
Tar-Stream oder ueber ein Staging-PVC in den Cluster uebertragen werden.

## Xapian als zu pruefende Alternative

Das verwendete Web-Image enthaelt bereits:

- `xapian-haystack` 3.1.0,
- Xapian 1.4.24,
- `xapian_backend.XapianEngine`.

Aktiv ist trotzdem Whoosh. Xapian ist eine native Suchengine und kann die
Segment- und Commit-Kosten von Whoosh vermeiden. Ein erster Mikrobenchmark
unter gleichzeitiger Volllast zeigte aber keinen sicheren Geschwindigkeitsvorteil:
Die groesste Mail brauchte mit Xapian 561 Sekunden, mit Whoosh im laufenden
Vier-Worker-Aufbau rund 408 Sekunden. Wegen unterschiedlicher CPU-Konkurrenz
ist das kein fairer Backendvergleich, belegt aber, dass der native Indexer die
teure Python-Aufbereitung des Mailtexts nicht beseitigt.

Vor einer Umstellung sind deshalb auf einer restaurierten Produktionskopie mit
identischer exklusiver CPU-Zuteilung mindestens zu messen:

- Vollaufbauzeit und Spitzenspeicher,
- Indexgroesse,
- Treffer fuer bekannte Begriffe, Listenfilter und Datumsbereiche,
- Antwortzeit breiter und enger Suchen,
- inkrementelle Archivierung neuer Mails,
- Verhalten nach Pod- und Node-Neustart,
- Backup und Restore des Index.

Die Konfiguration erfolgt ueber `HAYSTACK_CONNECTIONS` mit
`xapian_backend.XapianEngine` und einem neuen, leeren Indexpfad. Ein
Whoosh-Verzeichnis darf nicht als Xapian-Index weiterverwendet werden. Die
Umstellung ist ein eigener, rueckrollbarer GitOps-Vorgang und nicht Teil eines
laufenden Incident-Reindex.

## Konsequenz

- Keine Vollindexierung mehr im Web-Pod oder direkt im produktiven Indexpfad.
- Keine Parallelisierung nach Zeilenanzahl.
- Kein Batch ohne Byte-Limit.
- Uebergrosse Mailtexte im Suchindex begrenzen, wenn die fachliche Abnahme
  bestaetigt, dass Volltexttreffer hinter dem Limit entbehrlich sind.
- Kein speicherintensiver Job auf einem Node, dessen reale Grundlast plus
  moeglicher Jobverbrauch den physischen RAM erreicht.
- CephFS/NFS nur fuer Checkpoints und Artefakttransport einplanen, solange ein
  direkter Benchmark keinen Vorteil zeigt.
- Xapian auf einer Restore-Kopie nach einem Body-Limit benchmarken und nur bei
  messbarem Vorteil sowie korrekter Suchfunktion dauerhaft aktivieren.
