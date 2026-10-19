# ADR 0006 - LiteLLM fuer Blablador mit Hermes-Codex-Fallback

- **Status:** Umgesetzt und am 2026-10-18 vollstaendig abgenommen
- **Datum:** 2026-10-12
- **Freigegeben:** 2026-10-12
- **Ersetzt:** ADR 0005
- **Kontext:** Hermes auf `hermes01` soll Blablador als primaeren Modellpfad
  nutzen und den vorhandenen Codex-OAuth-Zugang als unabhaengigen Fallback
  behalten.

## Ausgangslage

Zum Entscheidungszeitpunkt lief Hermes auf `hermes01` (`192.168.2.37`) direkt
mit `openai-codex` und `gpt-5.6-sol`. Seit der Abnahme am 18.10.2026 ist
`hermes-blablador` der Primaerpfad; Codex bleibt der direkte Fallback und
Rollbackpfad. Die Codex-Authentisierung besteht aus von Hermes verwalteten
OAuth-Access- und Refresh-Tokens. Es ist kein OpenAI-Platform-API-Key vorhanden.

Fuer Blablador existiert ein API-Key. Die authentifizierte Modellabfrage am
12.10.2026 bestaetigte `alias-code` als account-sichtbare Modell-ID. Der Key
liegt ausserhalb des Repositories in einer Datei mit Modus `0600` und darf nie
in Logs, Shell-Argumenten oder Dokumentation erscheinen.

Ein Claude-Abonnement und ein Codex-/ChatGPT-Abonnement enthalten keine
separaten Anthropic-Console- beziehungsweise OpenAI-Platform-API-Keys. Damit
sind das in ADR 0005 beschlossene gleichgewichtete Routing und der
provideruebergreifende LiteLLM-Failover nicht ohne weitere kostenpflichtige
API-Vertraege umsetzbar.

LiteLLM `v1.104.0` kann Codex als Client an einen LiteLLM-Proxy anbinden, aber
Codex-OAuth nicht als Upstream-Provider verwalten. Ein eigener Adapter muesste
Hermess Refresh-Token in den Cluster kopieren, das Token erneuern und einen
nicht nativ unterstuetzten ChatGPT-Backendpfad nachbilden. Diese Kopplung wird
aus Sicherheits- und Wartungsgruenden ausgeschlossen.

Die fachliche Freigabe der Verarbeitungs-, Aufbewahrungs- und
Trainingsbedingungen fuer Blablador und Codex wurde am 12.10.2026 durch den
Betreiber bestaetigt.

## Entscheidung

LiteLLM wird als stateless, OpenAI-kompatible Sicherheitsgrenze fuer genau
einen Upstream betrieben:

- oeffentlicher Modellname: `hermes-blablador`
- LiteLLM-Provider: OpenAI-kompatibel
- Upstream-Modell: `openai/alias-code`
- Upstream-Basis: `https://api.blablador.fz-juelich.de/v1/`

Hermes verwendet nach erfolgreicher Abnahme den Gateway als Primaerprovider.
Hermess native Top-Level-Liste `fallback_providers` enthaelt als einzigen
Fallback `openai-codex` mit `gpt-5.6-sol`. Die Codex-OAuth-Credentials bleiben
ausschliesslich auf `hermes01`; LiteLLM sieht und speichert sie nie.

Jeder neue Hermes-Turn startet erneut ueber `hermes-blablador`. LiteLLM macht
weder Load Balancing noch provideruebergreifende Retries. Wenn der Primaerpfad
vor einer verwertbaren Ausgabe gemaess Hermess Standardklassifizierung
scheitert, wechselt Hermes fuer diesen Turn direkt zu Codex.

## Architektur und Datenfluss

Die GitOps-App folgt dem vorhandenen Base-/Overlay-Muster:

```text
apps/base/litellm/
apps/overlays/main/litellm/
```

Das Main-Overlay wird vom vorhandenen Apps-ApplicationSet aufgenommen. Der
Hostname `litellm.jit.services` wird in
`apps/overlays/main/cluster-config.yaml` gepflegt. Das bestehende Wildcard-DNS
fuer `*.jit.services` zeigt bereits auf den Ingress-LoadBalancer
`192.168.2.246`; ein DNS-Edit ist nicht vorgesehen.

Der Primaerpfad lautet:

```text
Hermes (192.168.2.37)
  -> HTTPS litellm.jit.services:443
  -> ingress-nginx (192.168.2.246)
  -> ClusterIP-Service litellm:4000
  -> HTTPS api.blablador.fz-juelich.de:443
```

Der Fallback umgeht den Cluster bewusst:

```text
Hermes
  -> vorhandener openai-codex-Provider
  -> https://chatgpt.com/backend-api/codex
```

Damit bleiben die beiden Auth-Domaenen getrennt. Der Cluster besitzt nur den
Blablador-Key; Hermes besitzt nur den Gateway-Key und seine bestehende
Codex-OAuth-Sitzung.

## LiteLLM-Modell und Request-Policy

LiteLLM exponiert genau eine Modellgruppe `hermes-blablador` mit genau einem
Deployment und einer stabilen `model_info.id` `hermes-blablador`. Es gibt keine
Wildcard-Modelle, Gewichte, Fallbacks oder alternativen Provider.

Die Routerkonfiguration setzt `num_retries: 0`. Ein Fehler wird nach genau
einem Upstream-Versuch an Hermes zurueckgegeben. LiteLLM darf einen Request
nicht selbst auf demselben kostenpflichtigen Upstream wiederholen.

Ein immer aktiver, read-only eingebundener `async_pre_call_hook` prueft vor dem
Upstream-Aufruf die von LiteLLM normalisierte Body-Kopie und die bereinigten
Header unter `proxy_server_request`:

- `model` muss exakt `hermes-blablador` sein.
- `messages` muss vorhanden und listenfoermig sein.
- Erlaubt werden nur die nach dem Provider-Contract empirisch bestaetigten
  OpenAI-Chat-Parameter.
- Hermess Streaming-Erweiterung wird ausschliesslich in der gegen Blablador
  verifizierten Form `stream_options: {include_usage: true}` akzeptiert.
- `extra_body`, unbekannte providergerichtete Felder, Routing-, Retry-,
  Fallback-, Drop-, API-Basis- und Timeout-Overrides werden mit HTTP 400
  abgewiesen.
- Alle clientseitigen `x-litellm-*`-Steuerheader werden abgewiesen.
- Die Policy veraendert oder loggt den Request nicht. Fehlermeldungen nennen
  nur Feldnamen, nie Feldwerte.

LiteLLMs vor der Policy entfernte interne Kontrollfelder werden mit dem exakt
gepinnten Image darauf getestet, dass sie wirkungslos bleiben. Die erwartete
Normalisierungsform und Strip-Liste sind ein Upgrade-Contract. Eine Aenderung
blockiert das Upgrade, bis Policy und ADR geprueft wurden.

`drop_params` bleibt explizit `false`. `LITELLM_DROP_PARAMS`,
deploymentweites `drop_params`, `additional_drop_params` und der unsichere
Master-Key-Bypass sind verboten.

## Hermes-Routing und Fehlerverhalten

Die zentrale Rolle `hermes_agent` auf `cfgmgmt01:/etc/ansible` verwaltet einen
benannten, OpenAI-kompatiblen Provider fuer:

- Base URL `https://litellm.jit.services/v1`
- Modell `hermes-blablador`
- Chat-Completions-Transport
- Gateway-Key aus Ansible Vault

Die exakte YAML-Struktur wird aus der auf `hermes01` installierten
Hermes-Version abgeleitet und ueber `hermes config check` sowie die effektive
Konfiguration validiert. Vermutete oder veraltete Optionsnamen sind nicht
zulaessig.

Bei der Designabnahme lief Hermes Agent `v0.21.5+6827.g819cc3c` auf Commit
`819cc3cbe02104c420ea32f1f1a924247d42eaf8`. Diese Version unterstuetzt den
nativen Administrator-Scope `/etc/hermes`: Dessen `config.yaml` wird als
verwaltetes Overlay ueber die Benutzerkonfiguration gelegt, und dessen `.env`
ueberschreibt nur gleichnamige Umgebungswerte. Die Umsetzung pinnt diese
Semantik und fuehrt waehrend Rollout und Abnahme kein Hermes-Update durch.

Die effektive Primaerkonfiguration setzt den Gateway-Provider und
`hermes-blablador`. Die Top-Level-Liste `fallback_providers` enthaelt genau:

```yaml
fallback_providers:
  - provider: openai-codex
    model: gpt-5.6-sol
```

Der explizite Override
`model_overrides.custom.hermes-blablador.supports_reasoning` mit Wert `false`
markiert den Alias fuer die gepinnte Hermes-Version als nicht reasoning-faehig.
Dadurch fuegt Hermes nicht automatisch `reasoning_effort` hinzu; dieses nicht
gegen Blablador abgenommene Feld bleibt an der Gateway-Grenze verboten.

Hermess regulaerer App-Level-Retry wird mit `agent.api_max_retries: 1` auf einen
Versuch begrenzt. Die Schleife startet mit Zaehler `0` und laeuft nur, solange
er kleiner als `api_max_retries` ist. Als fest verdrahtete Ausnahme baut die
gepinnte Hermes-Version den Primaerclient nach einem erschoepften transienten
Connection- oder Timeoutfehler einmal neu auf und sendet einen letzten
Primaerversuch; dieser Pfad ist nicht separat konfigurierbar. HTTP-Fehler wie
429 gehen ohne diesen Transport-Rebuild direkt zum Fallback. Die zusaetzliche
Auto-Recovery-Schleife wird mit `agent.auto_recovery_cycles: 0` deaktiviert,
damit ein ausgefallener Primaerpfad nicht minutenlang vor dem Codex-Fallback
wiederholt wird. Damit kann ein upstream-seitig bereits angenommener Request
bei verlorenem Transportergebnis im Ausnahmefall einmal doppelt ausgefuehrt
werden; dieses begrenzte Verfuegbarkeitsrisiko wird fuer die gepinnte Revision
akzeptiert und vor jedem Hermes-Upgrade erneut bewertet.

Es gilt bewusst Hermess eingebaute Fallback-Klassifizierung. Neben Timeouts,
Verbindungsfehlern, 429 und 5xx koennen daher je nach Hermes-Version auch
Auth-, Billing- oder Accountfehler Codex aktivieren. Dieser
Verfuegbarkeits-Trade-off wurde am 12.10.2026 akzeptiert. Providerwechsel
muessen im Hermes-Status und in technischen Logs sichtbar bleiben; ein
Codex-Fallback darf bei der Abnahme nicht als erfolgreicher Gateway-Test
gewertet werden.

Nach bereits ausgelieferten Streaming-Daten findet kein Providerwechsel statt.
Request-Format-, Context-Window- und Content-Policy-Verhalten werden gegen die
installierte Hermes-Version getestet und nicht durch einen zweiten
LiteLLM-Retry-Layer veraendert.

## Kubernetes und Secret-Grenze

Die App umfasst Namespace, ConfigMaps fuer LiteLLM, Request-Policy und
Egress-Probe, Deployment, Service, CiliumNetworkPolicy, Ingress, einen
ArgoCD-`PostSync`-Pruefjob, KSOPS-Generator und SOPS-Secret. Sie laeuft mit
genau einer Replica, einem Uvicorn-Worker und `strategy.type: Recreate`.

Es gibt kein PostgreSQL, Redis, PVC, HPA, PDB, ServiceMonitor, Admin-UI,
Spend-Tracking, Prompt-Logging oder externe Callback-Ziele. Der kurze Ausfall
bei einem Update ist akzeptiert, weil Hermes auf Codex zurueckfallen kann.

Das SOPS-Secret enthaelt genau:

- `BLABLADOR_API_KEY`
- `LITELLM_MASTER_KEY`

Der Master-Key besteht aus `sk-` plus 64 kleinen Hex-Zeichen aus 32
Zufallsbytes. Das Secret erhaelt ArgoCD-Sync-Wave `-1`, das Deployment Wave
`0`. Eine nicht geheime Secret-Revision in der Pod-Template-Annotation erzwingt
nach einer Rotation den kontrollierten Pod-Ersatz.

Das Deployment verwendet das offizielle Non-Root-Image
`ghcr.io/berriai/litellm-non_root`. `v1.104.0` bleibt der zu verifizierende
Kandidat. Vor dem ersten Manifest-Commit werden Provenienz beziehungsweise
Signatur, Registry-Digest und HIGH-/CRITICAL-Vulnerabilities geprueft. Das
Manifest pinnt Tag und Digest. Die kompromittierten Versionen `1.82.7` und
`1.82.8` bleiben ausgeschlossen.

Der Pod wird gehaertet mit:

- festem Non-Root-UID/GID, `RuntimeDefault` und ohne Privilege Escalation
- Drop aller Linux-Capabilities
- read-only Root-Dateisystem
- begrenzten `emptyDir`-Mounts fuer `/tmp`, `/app/.cache` und
  `/app/migrations`
- `automountServiceAccountToken: false`
- Requests `250m`/`512Mi` und Limits `1`/`1Gi`

Die Imagewerte `PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries` und
`PRISMA_CLI_PATH` bleiben unveraendert. `LITELLM_LOCAL_MODEL_COST_MAP=True`
verhindert einen Live-Download der Preisliste. Message- und Debug-Logging sind
deaktiviert. Probes verwenden nur lokale LiteLLM-Health-Endpunkte und erzeugen
keine Provider-Anfragen.

## Ingress- und Egress-Grenze

Der Ingress verwendet `letsencrypt-prod` und akzeptiert nur die
urspruengliche Peer-Adresse `192.168.2.37`. Wegen des global vertrauten
`X-Forwarded-For` wird zwingend `$realip_remote_addr`, nicht `$remote_addr`,
geprueft.

Extern erreichbar sind nur:

- `POST /v1/chat/completions`
- `GET /v1/models`

Andere Methoden, Slash-Varianten, Unterpfade, Health-, Docs-, OpenAPI-, UI-
und Managementpfade werden abgewiesen. Der Ingress setzt 1 MiB Body-Limit,
30 Requests pro Minute, Burst 10 ohne Delay und
`${realip_remote_addr}` als Rate-Key.

LiteLLMs Admission Control startet mit vier laufenden und vier wartenden
Requests sowie einer Sekunde Queue-Timeout.

Die CiliumNetworkPolicy erlaubt:

- Ingress zu TCP/4000 nur vom tatsaechlich gerenderten Ingress-Controller
- DNS per TCP/UDP nur zum Cluster-DNS
- TCP/443 nur zu `api.blablador.fz-juelich.de`
- fuer diesen HTTPS-Pfad sowohl `toFQDNs.matchName` als auch das passende
  `toPorts.serverNames`-SNI

OpenAI-, Anthropic-, allgemeiner Internet-, CIDR-, private, Link-Local- und
Metadata-Egress sind nicht erlaubt. Die aktive Cilium-L7-Proxy-Funktion,
CNAME-/IP-Rotation, falsches SNI und ein fremder HTTPS-Host werden praktisch
geprueft.

Diese Egress-Abnahme erfolgt ohne `kubectl exec`: Ein per GitOps verwalteter,
gehaerteter ArgoCD-`PostSync`-Job verwendet dasselbe gepinnte Image und dieselbe
Cilium-Egress-Identitaet, aber weder Service-Selector noch Secret. Er prueft
einen erlaubten TLS-Handshake zu Blablador sowie das Scheitern von fremdem DNS,
privaten/Metadata-Zielen und falschem SNI. Der Job erzeugt keine Inference-
Anfrage und muss den Sync bei einer aufgeweichten Netzgrenze fehlschlagen lassen.

## Tests und Abnahme

Vor Manifesten wird `alias-code` mit dem geschuetzten Blablador-Key direkt
getestet:

1. normale Chat-Completion
2. Stream mit mindestens zwei Chunks
3. deterministischer Tool Call in der von Hermes erwarteten Form

Abnahmeprotokolle enthalten nur Datum, Status, Latenz und Schemaergebnis,
keine Keys, Prompts, Antworten oder personenbezogenen Inhalte.

Lokale Contract-Tests im exakten LiteLLM-Image pruefen:

- Laden und Unumgehbarkeit der Request-Policy
- gepinnte Proxy-Normalisierung und Strip-Liste
- genau einen Blablador-Upstream-Versuch bei Erfolg und Fehler
- unveraenderte Weitergabe kontrollierter 400-, 401-, 429- und 5xx-Fehler
- kein Providerwechsel nach dem ersten Streaming-Chunk
- sichere Wirkungslosigkeit vorab entfernter Kontrollfelder

Statische Manifesttests pruefen Image-Digest, Replica/Worker/Strategie,
Security Context, Ressourcen, writable Mounts, Secret-Schluessel, deaktivierte
Features, exakte Ingresspfade und ausschliesslich Blablador-DNS-/FQDN-/SNI-
Egress. Sie pruefen ausserdem, dass der Egress-Probe-Job dieselbe Policy-
Identitaet, aber weder Service-Selector noch Secret-Zugriff besitzt.

Die Live-Abnahme prueft:

- ArgoCD `Synced`/`Healthy`, Pod-Probes und TLS-Zertifikat
- gueltiger Gateway-Key mit 2xx und fehlende Authentifizierung mit HTTP 401
- vorhandener falscher Gateway-Key mit HTTP 400 und strukturellem Fehlertyp
  `no_db_connection`; das ist LiteLLM-`v1.104.0`-Verhalten im bewusst
  datenbanklosen Master-Key-Modus und muss vor jedem Provideraufruf entstehen
- Pfad-/Methodenmatrix und XFF-Spoofing von einem anderen LAN-Host
- HTTP 413, 429 und 503 fuer Body-, Rate- und Admission-Grenzen
- Blablador Chat, Streaming und Tool Call ueber den Gateway
- erlaubte CNAME-/IP-Rotation sowie blockierte fremde Ziele und falsches SNI
- Master-Key-Rotation: neuer Key erfolgreich, alter Key HTTP 400 mit
  `no_db_connection` und ohne Provideraufruf

Erst danach wird die Ansible-Rolle aktiviert. Syntaxcheck, Check-Mode,
gezielter Rollout auf `hermes01`, effektive Konfigurationspruefung und ein
idempotenter Zweitlauf sind Pflicht.

Der End-to-End-Test umfasst einen normalen Hermes-Turn, Streaming und einen
Tool Call ueber Blablador. Anschliessend wird das Ingress-Rate-Limit in einem
Wartungsfenster mit policy-abgewiesenen Requests auf exakt
`POST /v1/chat/completions` kontrolliert erreicht. Diese Requests muessen vor
dem Blablador-Aufruf mit HTTP 400 enden und duerfen keine Providerkosten
erzeugen. Ein unmittelbar folgender, dedizierter Hermes-Testturn muss den 429
erkennen und sichtbar ueber Codex erfolgreich sein. Nach Ablauf des Rate-Limits
muss der naechste Turn wieder `hermes-blablador` verwenden.

## Rollout und Rotation

Der Rollout erfolgt in dieser Reihenfolge:

1. LiteLLM-Image verifizieren und immutable pinnen.
2. Blablador-Contract fuer `alias-code` im gepinnten Image schliessen.
3. Gateway-Manifeste und verschluesselte Secrets implementieren und lokal
   pruefen.
4. GitOps-PR mergen und ArgoCD-Abnahme abschliessen, waehrend Hermes weiterhin
   Codex als Primaerprovider nutzt.
5. Gateway-Master-Key einmal rotieren und neuen/alten Key pruefen.
6. Hermes-Rollensupport zunaechst deaktiviert committen und testen.
7. Gateway als Primaerprovider sowie Codex-Fallback separat aktivieren.
8. End-to-End-, Failover-, Idempotenz- und Rollback-Drill abschliessen.

Task 8 rotiert den Master-Key einmalig, waehrend Hermes weiterhin Codex als
Primaerprovider verwendet. Der neue Key muss erfolgreich sein; der alte Key
muss mit HTTP 400 und `no_db_connection` vor dem Provideraufruf scheitern.

Bei jeder spaeteren produktiven Master-Key-Rotation wird Hermes zuerst ueber
den verwalteten Rollbackpfad auf Codex als Primaerprovider gesetzt und dieser
Zustand verifiziert. Danach werden der SOPS-Key samt Secret-Revision per GitOps
und derselbe neue Key per Ansible Vault auf Hermes ausgerollt. Erst nach
erfolgreicher Gateway-Pruefung mit dem neuen Key wird Blablador wieder als
Primaerpfad aktiviert. Der Ablauf verlaesst sich bewusst nicht darauf, dass
Hermes den HTTP-400-Fehlertyp des alten Keys als Fallback-ausloesend einstuft.

## Rollback

Der schnellste Rollback ist ausschliesslich Hermes-seitig:

1. verwaltete Gateway-Aktivierung deaktivieren
2. `openai-codex` mit `gpt-5.6-sol` wieder als Primaerprovider wirksam machen
3. Hermes kontrolliert neu starten
4. effektive Konfiguration und einen Testturn pruefen

LiteLLM kann ungenutzt fuer die Diagnose weiterlaufen. Ist der Cluster-Workload
selbst fehlerhaft, wird sein GitOps-Commit revertiert und ArgoCD abgewartet.
Mangels Datenbank und Volumes existieren weder Datenmigration noch Restore.

## Bewusste Nicht-Ziele

- OpenAI-Platform- oder Anthropic-API als LiteLLM-Upstream
- Codex-OAuth, Refresh-Tokens oder ChatGPT-Backendzugriff aus dem Cluster
- LiteLLM-Load-Balancing oder provideruebergreifender Gateway-Failover
- Datenbank, Redis, Persistenz oder mehrere LiteLLM-Replicas
- Response-Caching im initialen Gateway-Rollout
- Admin-UI, virtuelle Keys, Benutzer-/Teamverwaltung oder Spend-Tracking
- Prompt-Logging, externe Observability-Callbacks oder zusaetzliche API-Pfade
- automatische Auswahl anderer Blablador-Modelle neben `alias-code`

## Rollout-Gates

- [x] `alias-code` besteht Chat-, Streaming- und Tool-Calling-Contract.
- [x] Blablador-Key liegt SOPS-verschluesselt im GitOps-Repo.
- [x] Dedizierter Master-Key liegt in SOPS und Ansible Vault.
- [x] Image-Provenienz, Digest und Vulnerability-Scan sind akzeptiert.
- [x] Request-Policy und gepinnter LiteLLM-Contract sind gruen.
- [x] Quell-IP-, XFF-Spoofing-, Pfad-/Methoden-, Body-, Rate- und
      Admission-Tests sind gruen.
- [x] Cilium erlaubt nur Cluster-DNS und Blablador HTTPS mit FQDN plus SNI.
- [x] Chat, Streaming und Tool Call funktionieren live ueber den Gateway.
- [x] Master-Key-Rotation akzeptiert den neuen und verweigert den alten Key.
- [x] Hermes verwendet Blablador als Primaerpfad und Codex sichtbar als
      Fallback; danach kehrt ein neuer Turn zu Blablador zurueck.
- [x] Hermes-Rollback auf Codex wurde aus Ansible erfolgreich geuebt.

## Konsequenzen

Der Gateway bleibt trotz nur eines Upstreams sinnvoll: Er trennt den
Blablador-Key von Hermes, erzwingt einen engen Request-Contract und legt
Ingress-, Rate-, Admission- und Egress-Grenzen zentral fest. Provider-Failover
ist dagegen bewusst eine Hermes-Verantwortung.

`alias-code` ist ein von Blablador gepflegter, veraenderlicher Alias. Ein
Backendwechsel kann Verhalten aendern, ohne dass sich die Konfiguration aendert.
Deshalb sind die Provider-Contracts nicht nur Erstabnahme, sondern auch ein
verpflichtender Wiederholungstest bei beobachteten Verhaltensaenderungen und vor
LiteLLM-/Hermes-Upgrades.

Response-Caching bleibt deaktiviert. Der aktuelle Request-Contract erlaubt
keine clientgesteuerten Cache-Parameter, und der exakte Proxy-Contract fordert
bei einem erfolgreichen Request genau einen Blablador-Aufruf. Ein Cache-Hit
wuerde diese Semantik auf null Aufrufe aendern, Antworten ueber die Anfrage
hinaus im Speicher halten und koennte Backendwechsel des veraenderlichen Alias
oder veraltete Tool-Antworten verdecken.

Eine spaetere Cache-Einfuehrung ist ein eigener freigabepflichtiger
Architektur-Change. Der erste vertretbare Schritt waere ausschliesslich ein
operatorgesteuerter, kurzlebiger und hart begrenzter In-Memory-Cache in der
bestehenden einzelnen Replica; ohne Redis, Persistenz oder Client-Overrides.
Streaming, Tool Calls und Abnahmetests bleiben dabei ungecached. Vor einem
Rollout muessen die Cache-Konfiguration gegen das gepinnte LiteLLM-Image
verifiziert, Cache-Miss mit genau einem und Cache-Hit mit null Provideraufrufen
getestet sowie TTL, Groessenlimit und Inhaltsaufbewahrung dokumentiert werden.
Ein geteilter Redis-Cache erfordert wegen neuer Secrets, Egress-,
Verfuegbarkeits- und Datenschutzgrenzen eine neue ADR.

Der gewaehlte Hermes-Standard-Fallback maximiert Verfuegbarkeit, kann aber
Gateway- oder Billing-Fehler durch Codex-Nutzung maskieren. Sichtbare
Fallback-Hinweise, technische Logs und die explizite Pruefung der Rueckkehr zum
Primaerpfad sind daher Teil der Abnahme. Fuer einen alten Gateway-Key wird
dieser Fallback wegen der HTTP-400-Semantik nicht vorausgesetzt; Rotation nutzt
stattdessen den kontrollierten Codex-Primary-Ablauf.

Die Betriebsdokumentation wird zusaetzlich nach
`cfgmgmt01:/root/ansible/kellerio-docs/` kopiert. GitOps- und
Ansible-Aenderungen werden getrennt validiert und committet.

Technische Referenzen:

- [LiteLLM OpenAI Codex tutorial](https://docs.litellm.ai/docs/tutorials/openai_codex)
- [LiteLLM custom callback](https://docs.litellm.ai/docs/proxy/custom_callbacks)
- Hermes-Dokumentation `website/docs/user-guide/features/fallback-providers.md`
