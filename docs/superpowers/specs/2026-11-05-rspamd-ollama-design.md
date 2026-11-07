# Rspamd Ollama Design

## Ziel

Das eingebaute GPT-Modul von Rspamd bewertet unklare Nachrichten mit einem
lokalen Qwen-Modell. Die LLM-Bewertung ergaenzt die vorhandenen Regeln, ersetzt
sie nicht und darf bei einem Fehler weder die Annahme noch die Ablehnung einer
Nachricht blockieren.

## Eigentum und Systemgrenze

Die Scanner `spam01.jit.land` und `spam02.jit.land` liegen ausserhalb des
Kubernetes-Clusters und werden aus dem Repository `jit/ansible` verwaltet. Die
Umsetzung erfolgt dort in einem eigenen `rspamd_ollama`-Rollenbaustein und in
der vorhandenen `rspamd`-Rolle. Dieses GitOps-Repository bekommt keine
Ollama-Workload; es dokumentiert die Entscheidung, den Rollout und die
Ende-zu-Ende-Abnahme.

Ollama laeuft auf beiden Scannern lokal und bindet ausschliesslich an
`127.0.0.1:11434`. Rspamd verwendet sein seit Version 3.9 vorhandenes
GPT-Modul mit `type = "ollama"` und dem nativen Endpunkt `/api/chat`. Es gibt
keinen eigenen Lua-Client, keinen zentralen vLLM-Dienst und keine Verbindung
zum vorhandenen LiteLLM-Gateway.

## Versionen und Reproduzierbarkeit

Der erste Serverstand ist Ollama `v0.40.14`. Das Linux-amd64-Archiv wird mit
dem von GitHub veroeffentlichten SHA-256
`993e83d08c3d13d17c55009a3e2664c8a25445e644aec3a68bef5abb6abce67d`
installiert.

Der erste Modellkandidat ist `qwen3:8b` Q4_K_M. Vor einem Pull muss der
Registry-Manifest-Digest exakt
`sha256:500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`
entsprechen. Nach dem Pull wird der lokale Manifestinhalt erneut mit diesem
Digest geprueft. Der Modell-Blob ist
`sha256:a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f`.
Ein veraenderter Tag darf nicht still ausgerollt werden.

Falls `qwen3:8b` die Ressourcen- oder Latenzgrenzen nicht einhaelt, wird
`qwen3:4b` mit denselben Pinning- und Abnahmebedingungen als eigener
Folgeschritt bewertet. Beide Scanner muessen dasselbe Modell verwenden.

## Ollama-Laufzeit

Ollama laeuft als unprivilegierter Systembenutzer mit einem geharteten
systemd-Dienst. Der Dienst hat nur auf sein Modellverzeichnis Schreibzugriff,
bindet an Loopback und wird auf 4 CPU-Kerne sowie 8 GiB RAM begrenzt. Folgende
Laufzeitbedingungen sind fest:

- Cloud-Funktionen sind deaktiviert.
- Genau ein Modell und genau ein paralleler Request sind erlaubt.
- Die Warteschlange ist klein; Ueberlast liefert schnell einen Fehler.
- Das Modell bleibt geladen und wird nach dem Start vorgewaermt.
- Das Kontextfenster betraegt 4096 Tokens.
- Es werden keine Prompts oder Antworten durch zusaetzliches Debuglogging
  protokolliert.

Vor Aktivierung muessen beide Hosts mindestens 4 vCPU, AVX2 und genug RAM fuer
8 GiB Ollama-Limit plus 20 Prozent freie Reserve besitzen. `spam01` erfuellt
die Hardware- und Rspamd-Voraussetzungen am 05.11.2026; `spam02` war bei der
Vorpruefung nicht per SSH erreichbar und bleibt ein Rollout-Blocker.

## Rspamd-Datenfluss

Rspamd fuehrt zuerst die normalen Regeln, Bayes-, URL-, Reputation- und
Fuzzy-Pruefungen aus. Das GPT-Postfilter verwendet die eingebaute
Standardbedingung und ueberspringt unter anderem bereits abgelehnten Spam,
negative Ham-Scores, Whitelists, Replies, Bounces und hinreichend starke
`BAYES_SPAM`-Treffer.

Fuer verbleibende Nachrichten sendet das Modul Betreff, dargestellten
MIME-Absender, bis zu fuenf URL-Domains und begrenzten dargestellten Text. Das
Eingabelimit ist 1000 Woerter beziehungsweise ungefaehr 6000 Byte. Anhaenge
werden nicht uebertragen.

Der GPT-Antwortcache bleibt deaktiviert. Rspamd 4.1.0 bildet den Cache-Schluessel
nur aus Prompt, Modell, URL und dem Digest des ausgewaehlten MIME-Teils; Betreff,
Absender und URL-Domains fehlen. Zwei Nachrichten mit gleichem Text, aber
unterschiedlichem Betreff oder Absender wuerden sonst dieselbe Bewertung
erhalten. Weil das Modul ohne eigene Redis-Angabe auf die globale
Redis-Konfiguration zurueckfaellt, muss die Umsetzung per Contract-Test
nachweisen, dass das `gpt`-Modul keinen Cache-Kontext erzeugt. Ein Cache ist
erst zulaessig, wenn sein Schluessel saemtliche GPT-Eingaben abdeckt.

Qwen3 laeuft mit deaktiviertem Thinking, Temperatur 0, Seed 42,
4096-Token-Kontext und hoechstens 64 Ausgabetokens. Rspamd verwendet die
robustere Klartextantwort des Moduls. `reason_header` bleibt deaktiviert und
`autolearn` bleibt aus.

## Timeout und Fehlerverhalten

Der GPT-Request hat eine harte Obergrenze von 20 Sekunden und einen
Verbindungs-Timeout von einer Sekunde. Es gibt im SMTP-Pfad keine
Wiederholungsversuche. Verbindungsfehler, Ueberlast, Timeout und nicht
parsebare Antworten erzeugen kein wirksames GPT-Symbol.

Die Scanner verwenden derzeit den Rspamd-Standard `task_timeout = 8s`. Ein
aktiviertes GPT-Modul mit 20 Sekunden Symbol-Timeout ist damit unvereinbar.
Bei Aktivierung wird `task_timeout` deshalb explizit auf 25 Sekunden gesetzt;
im deaktivierten Zustand bleibt er bei 8 Sekunden. Die Regeln vor dem
GPT-Postfilter duerfen damit hoechstens 5 Sekunden verbrauchen, damit der
GPT-Request sein 20-Sekunden-Budget innerhalb von `task_timeout` ausschoepfen
kann. Benchmark und Shadow Mode messen deshalb die Gesamtlatenz pro Nachricht
bis zum Abschluss des GPT-Requests, nicht nur die Modell-Latenz; p99 der
Vorpruefungen ueber 5 Sekunden oder Task-Timeouts mit GPT-Beteiligung blockieren
die Score-Freigabe.

## Scores

Die erste Produktionsphase ist ein Shadow Mode. Dabei sind `GPT_SPAM`,
`GPT_HAM`, `GPT_MARKETING`, `GPT_PHISHING`, `GPT_SCAM`, `GPT_MALWARE` und
`GPT_UNCERTAIN` registriert, haben aber Gewicht 0. Wahrscheinlichkeit und
Kategorie bleiben in Rspamd sichtbar, ohne die Entscheidung zu beeinflussen.

Nach manueller Freigabe bekommt ausschliesslich `GPT_SPAM` ein Gewicht von
maximal 3. Alle Ham- und Kategorie-Symbole bleiben bei 0.

Das Gewicht allein begrenzt den Beitrag nicht: Rspamd 4.1.0 prueft die
numerische Klartextantwort nicht auf den Bereich 0 bis 1 und setzt fuer
`GPT_SPAM` den Faktor `(p - 0.5) * 2`. Eine Antwort `3` ergaebe Faktor 5 und bei
Gewicht 3 insgesamt 15 Punkte. Die GPT-Symbolgruppe erhaelt deshalb bereits im
Shadow Mode `max_score = 3`; ein Contract-Test prueft diese Gruppengrenze. Erst
damit kann Qwen vorhandene Spam-Scores nicht reduzieren und keine Nachricht
allein ueber die Ablehnungsgrenze von 15 Punkten heben. Antworten ausserhalb
von 0 bis 1 werden im Shadow Mode gezaehlt und gelten fuer den Benchmark als
nicht parsebar.

## Rollout und Abnahme

Die Rolle bleibt standardmaessig deaktiviert. Der Rollout erfolgt in dieser
Reihenfolge:

1. Ansible-Rolle, gepinnte Artefakte, Rspamd-Konfiguration und Score-Overrides
   offline validieren.
2. Ressourcen und Rspamd-Version auf beiden Hosts pruefen.
3. `qwen3:8b` auf beiden Hosts warm benchmarken; bei Bedarf `qwen3:4b`
   separat bewerten.
4. Das Modul mindestens 14 Tage und mindestens 100 Klassifikationen mit Score
   0 betreiben.
5. Die Shadow-Ergebnisse manuell pruefen und ausschliesslich `GPT_SPAM` bis
   maximal +3 freigeben.
6. Auf beiden Scannerpfaden eine echte SMTP-Zustellung nach `DATA` pruefen.

Der warme Benchmark muss p95 hoechstens 5 Sekunden, keinen Request ueber 20
Sekunden, mindestens 99 Prozent parsebare Antworten und mindestens 20 Prozent
RAM-Reserve auf beiden Hosts nachweisen. Oeffentliche deutsch- und
englischsprachige Ham-/Spam-Korpora dienen als Offline-Basis; Produktionsmails
werden nicht als neues Korpus archiviert.

Die offenen Gates 2 bis 6 stehen ab dieser Blaupause in
`docs/PRODUCTION-READINESS.md` (Abschnitt Mail).

Rollback bedeutet zuerst, alle GPT-Scores wieder auf 0 zu setzen. Falls das
nicht genuegt, wird `rspamd_ollama_enabled` deaktiviert. Ein bereits
installierter Ollama-Dienst wird dann gestoppt und fuer den Start deaktiviert;
Download und Installation laufen im deaktivierten Zustand nicht. Die vorhandene
Rspamd-Filterung und Redis/Bayes-Daten bleiben davon unberuehrt.
