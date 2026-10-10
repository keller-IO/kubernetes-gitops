# ADR 0005 - LiteLLM AI Gateway fuer Hermes

- **Status:** Angenommen, Umsetzung ausstehend
- **Datum:** 2026-10-07
- **Kontext:** Hermes auf `hermes01` soll mehrere LLM-Anbieter ueber einen
  zentralen, OpenAI-kompatiblen Gateway nutzen.

## Ausgangslage

Hermes laeuft auf `hermes01` (`192.168.2.37`) und verwendet derzeit direkt den
Provider `openai-codex` mit dem Modell `gpt-5.6-sol`. Die Providerwahl, der
Ausfallpfad und die Anbieter-Credentials liegen damit vollstaendig auf dem
einzelnen Client. Fuer OpenAI API, Anthropic und einen dritten
OpenAI-kompatiblen Anbieter soll es stattdessen einen zentral verwalteten,
OpenAI-kompatiblen Endpunkt geben.

Die neue Komponente muss in die vorhandene Betriebsweise passen:

- Workloads werden im kellerIO-Cluster deklarativ mit ArgoCD und Kustomize
  betrieben.
- Geheimnisse liegen ausschliesslich SOPS/age-verschluesselt im GitOps-Repo.
- `hermes01` wird weiterhin zentral ueber das Ansible-Repo auf `cfgmgmt01`
  verwaltet.
- Phase 1 braucht weder Benutzerverwaltung noch Kostenauswertung oder eine
  Web-Oberflaeche.
- Ein Provider-Ausfall darf Hermes nicht sofort unbenutzbar machen.

Die Versionen LiteLLM `1.82.7` und `1.82.8` waren von einem
[Supply-Chain-Incident](https://github.com/BerriAI/litellm/issues/24512)
betroffen. Eine nur nach Tag gepinnte oder ungepruefte Installation ist deshalb
nicht akzeptabel.

## Entscheidung

LiteLLM von BerriAI wird als stateless AI Gateway im kellerIO-Cluster
eingefuehrt. Hermes spricht nur noch den stabilen Modellnamen
`hermes-balanced` unter `https://litellm.jit.services/v1` an. LiteLLM verteilt
die Anfragen gleichmaessig auf drei Backends und uebernimmt provideruebergreifende
Retries:

1. OpenAI API,
2. Anthropic API,
3. Blablador unter `https://api.blablador.fz-juelich.de/v1/`.

Die konkreten Modell-IDs werden nicht geraten. Sie sind zusammen mit
Kompatibilitaetstests und den verschluesselten API-Schluesseln verpflichtende
Rollout-Gates. Bis diese Bedingungen erfuellt sind, wird kein produktiver
Workload angelegt und Hermes nicht umgestellt.

LiteLLM wird in Phase 1 mit genau einer Replica und ohne PostgreSQL, Redis oder
PVC betrieben. Der bestehende Hermes-Provider `openai-codex` bleibt als
clientseitiger Notfall-Fallback erhalten.

## Architektur und Netzgrenze

Die GitOps-App folgt dem bestehenden Base-/Overlay-Muster:

```text
apps/base/litellm/
apps/overlays/main/litellm/
```

Das Main-Overlay wird vom vorhandenen `appset-apps` automatisch als eigene
ArgoCD-Application aufgenommen. Der Hostname wird in
`apps/overlays/main/cluster-config.yaml` gepflegt. Das bestehende Wildcard-DNS
fuer `*.jit.services` zeigt bereits auf den Ingress-LoadBalancer
`192.168.2.246`; ein separater DNS-Edit ist daher nicht vorgesehen.

Der Datenpfad lautet:

```text
Hermes (192.168.2.37)
  -> HTTPS litellm.jit.services:443
  -> ingress-nginx (192.168.2.246)
  -> ClusterIP-Service litellm:4000
  -> OpenAI, Anthropic oder Blablador ueber HTTPS
```

Der Ingress verwendet `letsencrypt-prod` und akzeptiert ausschliesslich die
Quelladresse `192.168.2.37/32`. Extern erreichbar sind nur:

- `POST /v1/chat/completions`
- `GET /v1/models`

Andere Inference-, Health-, Dokumentations- und Managementpfade werden am
Ingress abgewiesen. Der ClusterIP-Service ist durch die Pod-Netzwerkpolicy nur
vom Ingress-Controller erreichbar; andere Cluster-Workloads duerfen die
Ingress-Sperre nicht ueber den Service umgehen.

LiteLLM `v1.104.0` verweigert den Start ohne sicheren Master-Key; der angebotene
`LITELLM_DANGEROUSLY_PERMIT_WEAK_OR_UNSET_MASTER_KEY`-Bypass ist ausdruecklich
nur fuer lokale Entwicklung bestimmt und wird nicht verwendet. Stattdessen
erhaelt Hermes einen mit mindestens 32 Zufallsbytes erzeugten, dedizierten
`LITELLM_MASTER_KEY`. Derselbe Wert liegt SOPS-verschluesselt im Cluster und per
Ansible Vault auf `cfgmgmt01`.
Provider-Schluessel bleiben davon getrennt. TLS, Quell-IP- und Pfad-Allowlist
sowie die Pod-Netzwerkpolicy bleiben Defense-in-depth.

Der globale Ingress vertraut derzeit `X-Forwarded-For` aus
`192.168.2.0/24`. Eine normale `$remote_addr`-Allowlist waere deshalb von einem
anderen LAN-Host mit einem gefaelschten Header umgehbar. Die LiteLLM-Regel muss
die vom RealIP-Modul erhaltene urspruengliche Peer-Adresse
`$realip_remote_addr` pruefen. Der gerenderte NGINX-Block und ein Negativtest
mit gefaelschtem `X-Forwarded-For: 192.168.2.37` sind Rollout-Gates.

## Routing und Fehlverhalten

`hermes-balanced` ist eine LiteLLM-Modellgruppe mit drei Deployments. Jedes
Deployment bekommt eine stabile `model_info.id`, damit Auswahl und Failover in
Response-Headern und technischen Logs nachvollziehbar sind, ohne Prompt- oder
Antwortinhalte zu protokollieren.

Die Routerkonfiguration verwendet `simple-shuffle`. `weight`, `order`, `rpm`
und `tpm` bleiben auf allen drei Deployments absent, damit regulaere Anfragen
langfristig annaehend zu je einem Drittel auf OpenAI, Anthropic und Blablador
verteilt werden.

Gewoehnliche Router-Retries garantieren bei 5xx- oder Verbindungsfehlern nicht,
dass ein noch unversuchtes Deployment gewaehlt wird. Deshalb gilt fuer den
asynchronen Proxy-Pfad explizit:

```yaml
router_settings:
  routing_strategy: simple-shuffle
  num_retries: 0
  enable_weighted_failover: true
  max_fallbacks: 2
```

Weighted failover waehlt nur aus den noch nicht versuchten Deployments derselben
Modellgruppe. Damit gibt es hoechstens drei Gesamtversuche und kein Deployment
wird wiederholt, solange ein anderes noch unversucht ist. LiteLLM `v1.104.0`
wendet diesen Pfad allerdings auf alle vom Provider als `APIError` abgebildeten
Fehler an, nicht nur auf 429, 5xx und Verbindungsfehler. Context-Window- und
Content-Policy-Fehler sind explizit ausgenommen. Die Eingabepolicy unten faengt
inkompatible Parameter vor dem Routing ab; andere Provider-4xx koennen weiterhin
bis zu zwei andere Deployments versuchen. Diese in `v1.104.0` nur fuer
asynchrone Router-Einstiege garantierte Semantik muss ueber den tatsaechlichen
Proxy-Endpunkt getestet werden; ein direkter synchroner `Router.completion()`-
Test ist kein Nachweis.

LiteLLMs Proxy akzeptiert standardmaessig proprietaere Steuerfelder aus Body und
Headern. Ein Client koennte damit unter anderem `num_retries`, `max_fallbacks`
oder `drop_params` ueberschreiben. Deshalb wird ein kleiner, immer aktiver
`async_pre_call_hook` als nicht geheime Python-Datei aus einer ConfigMap
read-only eingebunden und als nicht clientseitig deaktivierbarer Callback in
`litellm_settings.callbacks` registriert. Er prueft vor der Deploymentwahl die
von LiteLLM normalisierte Body-Kopie und die bereinigten Header unter
`proxy_server_request`:

- `model` muss exakt `hermes-balanced` sein.
- Erlaubt werden nur `model`, `messages` und die nach Auswahl der konkreten
  Modelle getestete Schnittmenge der von allen drei Backends unterstuetzten
  OpenAI-Chat-Parameter. `extra_body` ist nicht erlaubt.
- LiteLLM-Steuerfelder wie `num_retries`, `max_fallbacks`, `fallbacks`,
  `router_settings_override`, `drop_params`, `additional_drop_params`,
  `api_base`, `user_config` und Timeout-Overrides werden mit HTTP 400
  abgewiesen. Das Gleiche gilt fuer clientseitige `x-litellm-*`-Steuerheader.
- Die Policy verwirft oder veraendert keine Parameter und loggt weder Body noch
  Headerwerte. Sie ignoriert ausschliesslich die exakt versionierten, vom Proxy
  selbst injizierten Top-Level-Felder wie `metadata`; unbekannte
  providergerichtete Felder scheitern geschlossen vor dem ersten Provideraufruf.

Einige interne Kontrollfelder, darunter `callbacks`, `mock_response` und
`litellm_disabled_callbacks`, entfernt LiteLLM `v1.104.0` bereits vor dieser
Body-Kopie. Fuer sie kann der Hook kein HTTP 400 erzwingen. Negativtests muessen
stattdessen belegen, dass sie den Request nicht beeinflussen und keinen Callback
aktivieren oder deaktivieren. Die Tests fixieren zugleich die erwartete
Normalisierungsform; ein LiteLLM-Upgrade bleibt blockiert, wenn sich diese Form
oder die eingebaute Strip-Liste aendert.

Die Policy und ihre Negativtests sind Teil des Manifest-Changes. Damit wird
nicht auf die Vertrauenswuerdigkeit des Hermes-Prozesses oder die unveraenderte
Semantik kuenftiger LiteLLM-Versionen vertraut.

Folgende Grenzen sind beabsichtigt:

- Nach dem ersten an Hermes ausgelieferten Streaming-Chunk findet kein Wechsel
  des Providers statt.
- Content-Policy- und Context-Window-Fehler bekommen in Phase 1 keine eigene
  Fallback-Kette.
- Unbekannte oder nicht von allen drei Zielmodellen unterstuetzte Parameter
  werden von der Eingabepolicy abgewiesen und nicht still verworfen.
  `litellm_settings.drop_params` steht zusaetzlich explizit auf `false`;
  `LITELLM_DROP_PARAMS`, deploymentweites `drop_params` und
  `additional_drop_params` sind verboten.
- Es gibt keine Wildcard-Modelle. Clients koennen nicht beliebige Modelle der
  drei Anbieter durchreichen.
- Provider- und Client-Timeouts werden waehrend der Abnahme gemessen. Ein
  Gateway-Timeout wird erst danach so gesetzt, dass drei Versuche innerhalb
  des Hermes-Clientlimits liegen; ein ungemessener fixer Wert ist kein Teil
  dieser Entscheidung.

Alle drei ausgewaehlten Modelle muessen OpenAI Chat Completions, Streaming und
Tool Calling in der von Hermes erzeugten Form unterstuetzen. Unterschiedliche
Antwortqualitaet oder Tool-Semantik zwischen den Modellen ist ein bewusstes
Risiko des ausgeglichenen Routings und wird vor der Umschaltung praktisch
geprueft.

## Kubernetes und Secrets

Die App umfasst mindestens Namespace, ConfigMaps fuer LiteLLM und die getestete
Eingabepolicy, Deployment, Service, CiliumNetworkPolicy, Ingress,
KSOPS-Generator und SOPS-Secret. Der Sollzustand ist eine Replica. Das
Deployment verwendet `strategy.type: Recreate`, damit waehrend einer
Master-Key-Rotation niemals alte und neue Pods mit verschiedenen Schluesseln
gleichzeitig hinter dem Service stehen. Der kurze Gateway-Ausfall bei einem
Update wird fuer Phase 1 akzeptiert; Hermes wird bei geplanten Updates vorher
auf `openai-codex` zurueckgeschaltet. Das generierte Secret erhaelt ArgoCD-Sync-
Wave `-1`, das Deployment Wave `0`. Eine nicht geheime Secret-Revision in der
Pod-Template-Annotation erzwingt erst danach den kontrollierten Pod-Ersatz; eine
blosse Secret-Aenderung ohne neuen Pod ist unzureichend. Ein PodDisruptionBudget
wird fuer die einzelne Replica nicht gesetzt, damit Node-Wartung nicht blockiert
wird.

Das Deployment verwendet das offizielle Non-Root-Image
`ghcr.io/berriai/litellm-non_root`. Fuer die Umsetzung ist `v1.104.0` der
noch unverifizierte Ausgangskandidat. Vor dem ersten Manifest-Commit muessen
Signatur beziehungsweise Provenienz und der Registry-Digest verifiziert werden;
im Manifest stehen anschliessend Version und `sha256`-Digest. Floating Tags und
die kompromittierten Versionen `1.82.7`/`1.82.8` sind ausgeschlossen.

Der Pod wird gehaertet mit:

- `runAsNonRoot`, festem UID/GID-Wert und `allowPrivilegeEscalation: false`,
- `seccompProfile: RuntimeDefault`,
- Drop aller Linux-Capabilities,
- read-only Root-Dateisystem und begrenzten `emptyDir`-Mounts fuer `/tmp`,
  `/app/.cache` und `/app/migrations`,
- `automountServiceAccountToken: false`,
- CPU-Request `250m`, CPU-Limit `1`, RAM-Request `512Mi` und RAM-Limit `1Gi`.

Der Container laeuft mit genau einem Uvicorn-Worker und
`LITELLM_MODE=PRODUCTION`. `LITELLM_MIGRATION_DIR` und `XDG_CACHE_HOME` zeigen
auf die beschreibbaren Mounts. Die vom Non-Root-Image gesetzten Werte
`PRISMA_BINARY_CACHE_DIR=/opt/prisma/binaries` und `PRISMA_CLI_PATH` bleiben
unveraendert, damit die eingebauten Prisma-Binaries read-only verwendet und
nicht zur Laufzeit heruntergeladen werden. Die Admin-UI wird nicht vorbereitet
oder kopiert. Das RAM-Limit ist ein
Startwert fuer die datenbanklose API-only-Variante und muss im Lasttest sowie
im anschliessenden Betrieb gegen OOMs und den tatsaechlichen High-Water-Mark
validiert werden.

Readiness und Liveness verwenden die dafuer vorgesehenen LiteLLM-Endpunkte auf
Port 4000. Probes pruefen den Prozess und die geladene Konfiguration, erzeugen
aber keine kostenpflichtigen Provider-Anfragen. Die Werte werden nach den ersten
Messungen angepasst, nicht vorsorglich hochskaliert.

Die ConfigMap enthaelt nur nicht geheime Daten: drei exakte Modell-IDs,
Blablador-API-Basis, stabile Deployment-IDs, Router- und Loggingeinstellungen.
`secret.sops.yaml` enthaelt getrennt:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `BLABLADOR_API_KEY`
- `LITELLM_MASTER_KEY`

LiteLLM referenziert sie ausschliesslich ueber `os.environ/...`. Swagger,
ReDoc und das OpenAPI-Schema werden mit `NO_DOCS=True`, `NO_REDOC=True` und
`NO_OPENAPI=True` deaktiviert. Es gibt keine Datenbank, kein Redis, keinen PVC,
keine Admin-UI und keine dynamisch in einer Datenbank gespeicherte
Konfiguration. `LITELLM_LOCAL_MODEL_COST_MAP=True` verhindert den Download einer
Live-Preisliste beim Start. Message-Logging ist deaktiviert, Debug-Logging bleibt
aus und `drop_params` steht explizit auf `false`.

Eine `CiliumNetworkPolicy` erlaubt DNS nur zum Cluster-DNS und TCP/443 nur zu
`api.openai.com`, `api.anthropic.com` und
`api.blablador.fz-juelich.de`. `toFQDNs` begrenzt die aufgeloesten Ziel-IP-
Adressen; zusaetzliche `toPorts.serverNames` begrenzen das TLS-SNI auf dieselben
drei Namen. Ohne diese SNI-Regel koennte ein anderer HTTPS-Host auf einer mit
einem Provider geteilten IP weiterhin erreichbar sein. L7-DNS-Regeln erlauben
nur die fuer diese Provider erforderlichen Namen. Andere oeffentliche Ziele,
private Netze, Link-Local-Netze und Cloud-Metadatenadressen bleiben gesperrt.
Die im Repo gepinnte Cilium-Version `1.16.5` unterstuetzt diese Kombination.
Die fuer DNS- und SNI-Policy erforderliche L7-Proxy-Funktion muss in der
gerenderten Cilium-Konfiguration und im laufenden Agenten aktiv bestaetigt sein.
DNS-Aufloesung, CNAME-Ketten, rotierende Provider-IP-Adressen, falsches SNI und
jeder Negativfall werden praktisch validiert.

Der Ingress begrenzt den Request-Body und den einen Client mit folgenden
Annotationen:

```yaml
nginx.org/client-max-body-size: "1m"
nginx.org/limit-req-rate: "30r/m"
nginx.org/limit-req-burst: "10"
nginx.org/limit-req-no-delay: "true"
nginx.org/limit-req-key: "${realip_remote_addr}"
```

LiteLLMs workerlokale Admission Control startet mit:

```yaml
general_settings:
  max_in_flight_requests_per_worker: 4
  max_queued_requests_per_worker: 4
  admission_queue_timeout_seconds: 1
```

Diese Werte begrenzen Fehlkonfigurationen und einen kompromittierten
Hermes-Prozess, ohne Budgets oder eine Datenbank einzufuehren. Abgewiesene
Body-, Rate- und Concurrency-Grenzen werden getestet; spaetere Aenderungen
erfolgen nur nach Messung per GitOps.

## Hermes-Anbindung

Die zentrale Rolle `hermes_agent` auf `cfgmgmt01:/etc/ansible` erhaelt einen
benannten OpenAI-kompatiblen Provider mit:

- Base URL `https://litellm.jit.services/v1`,
- Modell `hermes-balanced`,
- dediziertem LiteLLM-Master-Key aus Ansible Vault.

Dieser Provider wird nach erfolgreicher Gateway-Abnahme zum Standard.
`openai-codex` bleibt in Hermes' `fallback_providers` als letzter Notfallweg.
Provider-Secrets werden nicht nach `hermes01` kopiert; sie existieren nur im
Kubernetes-Secret und zur verschluesselten Pflege im GitOps-Repo. Nur der
dedizierte Gateway-Key wird zusaetzlich per Ansible Vault an Hermes verteilt.
Seine Rotation ist ein koordinierter Wartungsablauf: Hermes zuerst auf
`openai-codex` zurueckschalten, den neuen SOPS-Key per `Recreate` ausrollen und
den neuen Pod gesund werden lassen, danach denselben Wert per Ansible Vault auf
Hermes verteilen und `hermes-balanced` wieder aktivieren. Vor der Reaktivierung
muss eine Anfrage mit dem neuen Key erfolgreich sein und eine mit dem alten Key
HTTP 401 liefern. Der alte Key wird danach nicht wiederverwendet.

Die konkrete YAML-Struktur wird aus der auf `hermes01` installierten
Hermes-Version und der bestehenden Rollenkonfiguration abgeleitet. Die
Umsetzung darf keine vermuteten Optionsnamen einfuehren und muss den gerenderten
Unterschied der Konfigurationsdatei vor dem Rollout zeigen.

## Rollout und Abnahme

Der Rollout erfolgt in dieser Reihenfolge:

1. Exakte Modell-IDs und Datenverarbeitungsbedingungen der drei Anbieter
   bestaetigen. Alle Modelle muessen Chat Completions, Streaming und Tool
   Calling unterstuetzen.
2. Provider-Credentials in `secret.sops.yaml` eintragen und vor jedem Commit
   mit den vorhandenen SOPS/KSOPS-Pruefungen als verschluesselt bestaetigen.
3. Image-Signatur/Provenienz, Digest und Vulnerability-Status der gewaehlten
   LiteLLM-Version pruefen.
4. Manifeste mit `nix develop --command just validate` pruefen. Den gerenderten
   Output zusaetzlich auf Namespace, Image-Digest, Security Context,
   Ressourcen, Ingress und entschluesselte Secret-Metadaten kontrollieren,
   ohne Werte auszugeben.
5. GitOps-PR mergen und ArgoCD `Synced`/`Healthy`, Pod-Probes sowie das
   ausgestellte TLS-Zertifikat abwarten. Keine mutierende Live-Cluster-Aktion
   durch einen Agenten ersetzt den GitOps-Weg.
6. Den gerenderten Ingress auf `pathType: Exact`, urspruengliche Peer-IP,
   Body- und Rate-Limit pruefen. Die Abnahmematrix umfasst falsche Methoden,
   einen angehaengten Slash/Unterpfad, `/`, Health, Docs, OpenAPI, UI und
   Managementpfade. Von einer nicht erlaubten Quelle muessen alle
   Inference-Pfade abgewiesen werden; ein gefaelschtes
   `X-Forwarded-For: 192.168.2.37` darf daran nichts aendern. Von `hermes01`
   funktionieren nur `POST /v1/chat/completions` und `GET /v1/models` mit dem
   gueltigen Gateway-Key.
7. Jeden Provider zunaechst direkt in einer kontrollierten Testumgebung
   pruefen. Danach ueber `hermes-balanced` normale, gestreamte und
   Tool-Calling-Anfragen ausfuehren. Die stabilen Deployment-IDs in den
   Headern muessen belegen, dass alle drei Backends erreichbar sind.
8. Failover in einer nicht produktiven Testkonfiguration mit einem echten
   Providerfehler pruefen. Seit LiteLLM Proxy `1.85.0` werden
   Mock-Fallback-Flags aus Proxy-Anfragen entfernt; ein scheinbar erfolgreicher
   Mock-Test gilt daher nicht als Nachweis. Separate Faelle muessen kontrolliert
   zwei aufeinanderfolgende 429- oder 5xx-Antworten vor einem erfolgreichen
   dritten Backend, einen Content-Policy-Fehler und einen Context-Window-Fehler
   abdecken. Nur der erste Fall muss genau drei verschiedene Deployment-IDs und
   drei Gesamtversuche ausloesen; die beiden ausgenommenen Fehler duerfen keinen
   Providerwechsel ausloesen.
9. Erst jetzt die Ansible-Rolle aendern. Syntaxcheck und Check-Mode ausfuehren,
   gezielt auf `hermes01` ausrollen und einen idempotenten Zweitlauf pruefen.
10. Einen echten Hermes-Dialog ueber die bestehende Nextcloud-Talk-Anbindung
    inklusive Tool-Aufruf testen. Anschliessend Deploymentzustand und
    Fehlerlogs beobachten.

Zusaetzlich prueft ein lokaler Routertest mit Stub-Backends 3.000
Auswahlentscheidungen ohne kostenpflichtige Provider-Aufrufe. Jedes Deployment
muss zwischen 30 und 37 Prozent der Picks erhalten. Requests mit einem
unbekannten providergerichteten Feld, einem nur von einem Backend unterstuetzten
Parameter, jedem im normalisierten Body erhaltenen verbotenen
LiteLLM-Steuerfeld sowie `x-litellm-num-retries` muessen vor dem ersten
Provideraufruf mit HTTP 400 scheitern. Fuer LiteLLMs vorab entfernte interne
Felder wird stattdessen deren Wirkungslosigkeit geprueft. Body-, Rate-,
In-flight- und Queue-Limits muessen mit den erwarteten 413-, 429- beziehungsweise
503-Antworten ablehnen.

Logs gehen ausschliesslich nach stdout/stderr. Debug-Logging bleibt standardmaessig
aus. Abnahmeprotokolle duerfen Statuscodes, Latenzen, Deployment-IDs und
Fehlerklassen enthalten, aber keine API-Schluessel, Prompts, Antworten oder
personenbezogenen Inhalte.

## Rollback

Der erste und schnellste Rollback betrifft nur Hermes: Die Ansible-Rolle setzt
`openai-codex` wieder als Standardprovider und rollt die vorherige gerenderte
Konfiguration auf `hermes01` aus. LiteLLM kann fuer die Diagnose weiterlaufen.

Ist der Cluster-Workload selbst fehlerhaft, wird ausschliesslich der
LiteLLM-GitOps-Commit revertiert und die normale ArgoCD-Synchronisation
abgewartet. Da Phase 1 keine Datenbank oder Volumes besitzt, gibt es keine
Datenmigration und keinen Restore-Schritt. Die SOPS-Datei bleibt in der
Git-Historie verschluesselt; kompromittierte Provider-Schluessel werden beim
jeweiligen Anbieter rotiert und nicht durch Git-Historienmanipulation
"entfernt".

## Sicherheitsbetrachtung

- Alle Prompts und Antworten koennen je nach Routerentscheidung an jeden der
  drei Anbieter gehen. Die fachliche Freigabe der Anbieter, Aufbewahrungs- und
  Trainingsbedingungen sowie gegebenenfalls AV-Vertraege sind deshalb vor dem
  Rollout verpflichtend.
- Hermes authentisiert sich mit einem eigenen, zufaelligen
  `LITELLM_MASTER_KEY`. Da virtuelle Workload-Keys ohne die bewusst
  ausgeschlossene Datenbank nicht zur Verfuegung stehen, ist die Verwendung
  des administrativen Keys fuer den einen Client ein akzeptierter Trade-off.
  Managementpfade bleiben am Ingress gesperrt; weitere Clients erfordern eine
  neue Auth- und Persistenzentscheidung.
- Der NGINX-Ingress muss die echte Adresse `192.168.2.37` sehen. Die Abnahme
  prueft dafuer `$realip_remote_addr` explizit; eine Allowlist, die nur den
  durch das global vertraute XFF ueberschriebenen `$remote_addr` prueft, gilt
  als fehlgeschlagen.
- Provider-Credentials werden nur als Pod-Umgebungsvariablen aus einem
  SOPS-Secret eingebunden. Sie duerfen weder in ConfigMaps noch in gerenderten
  Logs, Shell-Historien oder Dokumentation erscheinen.
- Das genaue Image-Pinning ist wegen des bekannten Supply-Chain-Incidents ein
  Freigabekriterium, keine optionale Haertung.
- FQDN-Policy allein ist keine Host-Isolation bei geteilten Ziel-IPs. Die
  kombinierte FQDN-, Port- und SNI-Policy ist deshalb verpflichtend.

## Bewusste Nicht-Ziele

- PostgreSQL, Redis, Persistenz oder mehrere LiteLLM-Replicas
- LiteLLM Admin-UI, virtuelle Keys, Benutzer- oder Teamverwaltung
- Budgets, Spend-Tracking, Prompt-Logging oder externe Observability-Callbacks
- Prometheus-, Grafana- oder Gatus-Integration in Phase 1
- Dynamische Modellpflege ueber API oder UI
- Ablosung des bestehenden Hermes-Fallbacks `openai-codex`
- Nutzung weiterer LiteLLM-Endpunkte wie Embeddings, Images, Audio oder
  Responses API

## Rollout-Gates

Vor der produktiven Umsetzung muessen alle folgenden Punkte mit konkreten
Werten oder Testergebnissen geschlossen sein:

- [ ] Exakte OpenAI-Modell-ID festgelegt und im Konto verfuegbar.
- [ ] Exakte Anthropic-Modell-ID festgelegt und im Konto verfuegbar.
- [ ] Exakte Blablador-Modell-ID festgelegt und im Konto verfuegbar.
- [ ] Alle drei Modelle mit Hermes-kompatiblem Streaming und Tool Calling
      getestet.
- [ ] Datenverarbeitungs-/Aufbewahrungsbedingungen aller drei Anbieter
      freigegeben.
- [ ] Drei API-Schluessel vorhanden und SOPS-verschluesselt.
- [ ] Dedizierter LiteLLM-Master-Key in SOPS und Ansible Vault vorhanden;
      koordinierter Rotationsweg dokumentiert.
- [ ] LiteLLM-Image signiert beziehungsweise Provenienz verifiziert, auf einen
      geprueften Digest gepinnt und nicht von dem bekannten Incident betroffen.
- [ ] Provider- und Hermes-Timeouts gemessen; Gateway-Timeout daraus abgeleitet.
- [ ] Quell-IP-Erkennung des Ingress mit `192.168.2.37` praktisch bestaetigt.
- [ ] XFF-Spoofing-, Pfad-/Methoden-, Body-, Rate- und Admission-Limit-Tests
      bestanden.
- [ ] Eingabepolicy weist unbekannte Felder, backend-spezifische Parameter und
      alle clientseitigen LiteLLM-Routing-/Retry-/Drop-Overrides vor Routing ab.
- [ ] Failover ueber alle drei Provider ohne Mock-Flags praktisch bestaetigt.
- [ ] Kombinierte FQDN-/SNI-Egress-Policy erlaubt nur die drei Provider und
      Cluster-DNS; beliebiges oeffentliches HTTPS sowie ein falsches SNI auf
      einer erlaubten Provider-IP sind praktisch blockiert.

## Konsequenzen und Folgearbeiten

Der stabile Alias entkoppelt Hermes von konkreten Provider-Modellnamen und
erlaubt spaetere Modellwechsel als GitOps-Aenderung. Gleichzeitig macht das
gleichgewichtete Routing Antwortqualitaet, Kosten und Datenschutz vom jeweils
ausgewaehlten Provider abhaengig. Ohne Datenbank gibt es keine dauerhafte
Kostenhistorie und ohne Redis keinen geteilten Routerzustand; beides ist bei
einer Replica beabsichtigt.

Die spaetere Erweiterung auf weitere Clients oder mehrere Replicas erfordert
eine neue Entscheidung zu Clientauthentisierung, persistentem Spend-Tracking,
Redis und gegebenenfalls Hochverfuegbarkeit. Die Betriebsdokumentation der
Umsetzung wird zusaetzlich nach
`cfgmgmt01:/root/ansible/kellerio-docs/` kopiert. GitOps- und Ansible-Aenderungen
werden getrennt, validiert und ausschliesslich mit den jeweils eigenen Dateien
committet.

Technische Referenzen:

- [LiteLLM Load Balancing](https://docs.litellm.ai/docs/proxy/load_balancing)
- [LiteLLM Provider Fallbacks](https://docs.litellm.ai/docs/proxy/reliability)
- [LiteLLM Config und deaktivierbare Dokumentationspfade](https://docs.litellm.ai/docs/proxy/configs)
