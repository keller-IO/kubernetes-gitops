# ADR 0009 - Lokale Ollama-Klassifikation fuer Rspamd

- **Status:** Angenommen; offline umgesetzt, produktiver Rollout gesperrt
- **Datum:** 2026-11-05
- **Umsetzung:** 2026-11-08

## Kontext

Die beiden externen Scanner `spam01.jit.land` und `spam02.jit.land` sollen
unklare Nachrichten zusaetzlich durch ein lokales Sprachmodell bewerten. Die
Bewertung ergaenzt Rspamd-Regeln, Bayes, URL-, Reputation- und Fuzzy-Pruefungen;
ein Modellfehler darf weder Annahme noch Ablehnung einer Nachricht blockieren.

Die Scanner liegen ausserhalb des Kubernetes-Clusters und werden aus dem
Repository `jit/ansible` verwaltet. Das GitOps-Repository dokumentiert
Architektur und Abnahme, besitzt aber keinen Ollama-Workload.

## Entscheidung

Jeder Scanner betreibt seine eigene Ollama-Instanz auf
`127.0.0.1:11434`. Rspamd verwendet sein eingebautes GPT-Modul mit
`type = "ollama"` und dem nativen Endpunkt `/api/chat`. Die Ansible-Rolle
`rspamd_ollama` steht unmittelbar vor der vorhandenen Rolle `rspamd` und bleibt
in beiden Produktions-Playbooks explizit deaktiviert, bis alle Live-Gates
bestanden sind.

Es gibt keinen Kubernetes-Service, keinen zentralen Inference-Server, keinen
eigenen Lua-Client und keine Verbindung zum LiteLLM-Gateway. Ein Ausfall bleibt
dadurch auf einen Scanner begrenzt und der Nachrichteninhalt verlaesst den
Scanner nicht.

## Reproduzierbarkeit

Der erste freigegebene Kandidat ist:

- Ollama `v0.40.14`
- Archiv `ollama-linux-amd64.tar.zst`
- Archiv-SHA-256
  `993e83d08c3d13d17c55009a3e2664c8a25445e644aec3a68bef5abb6abce67d`
- Modell `qwen3:8b` Q4_K_M
- Manifest
  `sha256:500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`
- Modell-Blob
  `sha256:a3de86cd1c132c822487ededd47a324c50491393e6565cd14bafa40d0b8e686f`

Ansible prueft den Registry-Digest vor dem Pull und lokales Manifest sowie Blob
danach. Ein veraenderter Modell-Tag oder ein abweichender Runtime-Pin bricht den
Rollout ab. Falls `qwen3:8b` die Abnahmegrenzen nicht erreicht, wird
`qwen3:4b` als eigener, erneut gepinnter Change bewertet.

## Laufzeitgrenze

Ollama laeuft als unprivilegierter Benutzer mit gehaertetem systemd-Dienst,
Cloud-Funktionen aus und Schreibzugriff nur auf das Modellverzeichnis. Fest
gelten:

- Loopback-Bindung, maximal 4 CPU-Kerne und 8 GiB RAM
- genau ein geladenes Modell, ein paralleler Request und Warteschlange 2
- 4096 Tokens Kontext und dauerhaft geladenes, inhaltsfrei vorgewaermtes Modell
- Debian x86_64, AVX2, mindestens 4 vCPU und 10 GiB Gesamt-RAM
- vor jedem Dienststart 8 GiB `MemoryMax` plus 20 Prozent Gesamt-RAM als
  `MemAvailable`

Im deaktivierten Zustand installiert und laedt die Rolle nichts. Existiert eine
Unit aus einem frueheren Rollout, stoppt und deaktiviert sie den Dienst.

## Rspamd- und Datenschutzvertrag

Das GPT-Modul sendet nur Betreff, dargestellten Absender, bis zu fuenf
URL-Domains und begrenzten dargestellten Nachrichtentext an das lokale Modell.
Anhaenge werden nicht uebertragen. Das Eingabelimit betraegt 1000 Woerter
beziehungsweise etwa 6000 Byte; Thinking ist aus, Temperatur 0, Seed 42,
Kontext 4096 und Ausgabe maximal 64 Tokens. `autolearn` und der
`reason_header` bleiben aus.

Der GPT-Antwortcache ist deaktiviert. Rspamd 4.1 bildet seinen Cache-Schluessel
ohne Betreff, Absender und URL-Domains und faellt ohne Modulausnahme auf die
globale Redis-Konfiguration zurueck. Deshalb enthaelt `redis.conf`
`disabled_modules = ["gpt"]`. Produktionsnachrichten werden weder als Korpus
archiviert noch durch zusaetzliches Debuglogging protokolliert.

Der Request hat 1 Sekunde Verbindungs- und 20 Sekunden Gesamt-Timeout, ohne
Retry. Fehler oder nicht parsebare Antworten erzeugen kein wirksames Symbol.
Bei deaktiviertem Modul bleibt Rspamd bei `task_timeout = 8s`; bei Aktivierung
gilt `25s`, damit der GPT-Request innerhalb des Task-Budgets enden kann.

## Score-Policy

Im Shadow Mode haben `GPT_SPAM`, `GPT_HAM`, `GPT_MARKETING`, `GPT_PHISHING`,
`GPT_SCAM`, `GPT_MALWARE` und `GPT_UNCERTAIN` Gewicht 0. Die gesamte
GPT-Symbolgruppe ist auf `max_score = 3` begrenzt, weil Rspamd 4.1 numerische
Klartextantworten nicht auf 0 bis 1 beschraenkt.

Nach bestandener Shadow-Abnahme darf ausschliesslich `GPT_SPAM` auf maximal +3
gesetzt werden. Alle Ham- und Kategorie-Symbole bleiben 0. Damit kann das Modell
weder einen bestehenden Spam-Score reduzieren noch allein die Reject-Schwelle
von 15 Punkten erreichen.

## Rollout-Gates

Der Rollout erfolgt pro Scanner und stoppt bei jedem fehlgeschlagenen Gate:

1. Offline-Contract, Syntaxcheck und Ansible-Diff sind gruen.
2. Hardware, freie Speicherreserve und Rspamd-Version sind auf beiden Hosts
   belegt.
3. Der warme Benchmark erreicht auf beiden Hosts p95 <= 5 Sekunden, keinen
   Request > 20 Sekunden, mindestens 99 Prozent parsebare Antworten und
   mindestens 20 Prozent RAM-Reserve.
4. Mindestens 14 Tage und 100 Klassifikationen je Scanner laufen mit allen
   Scores 0; p99 der Vorpruefungen bleibt <= 5 Sekunden und es gibt keinen
   GPT-beteiligten Task-Timeout.
5. Ergebnisse werden manuell geprueft und beide Scannerpfade bestehen eine
   echte SMTP-Zustellung nach `DATA`.

`spam02` war beim initialen Preflight nicht per SSH erreichbar. Daraus folgt
keine Aussage ueber seine Eignung; der Host bleibt ein Rollout-Blocker.

## Verworfene Alternativen

- **Ollama oder vLLM im Kubernetes-Cluster:** wuerde Nachrichtendaten ueber die
  Scannergrenze transportieren und neue Netz-, Kapazitaets- und
  Verfuegbarkeitsabhaengigkeiten schaffen.
- **Zentraler Ollama-Dienst fuer beide Scanner:** gemeinsamer Ausfallpunkt und
  unnoetige Uebertragung von Nachrichteninhalten.
- **LiteLLM-Gateway oder Cloud-Modell:** nicht fuer lokale Mailinhalte bestimmt;
  erhoeht Datenschutz- und Secret-Oberflaeche.
- **Eigener Lua-Client:** dupliziert das eingebaute Rspamd-Modul und vergroessert
  Wartungs- und Fehlerflaeche.
- **Aktiver Antwortcache:** fachlich falsch, solange sein Schluessel nicht alle
  uebertragenen Felder umfasst.

## Konsequenzen

Beide Scanner benoetigen Modell-RAM und lokale Installation. Die verdoppelte
Laufzeit vermeidet dagegen eine gemeinsame Inference-Abhaengigkeit. Rspamd
bleibt fail-open und seine vorhandenen Filter- sowie Redis/Bayes-Pfade bleiben
beim Rollback unveraendert.

Der Rollback setzt zuerst alle GPT-Scores auf 0 und deaktiviert danach bei
Bedarf `rspamd_ollama_enabled`; die Rolle stoppt und deaktiviert Ollama und
stellt den 8-Sekunden-Task-Timeout wieder her. Der operative Ablauf steht im
[Runbook](../runbooks/rspamd-ollama-integration.md). Nach Freigabe wird dessen
Betriebskopie nach
`192.168.23.19:/root/ansible/kellerio-docs/` uebertragen.
