# ADR 0011 - Embeddings fuer den Paperless-LLM-Index ueber den LiteLLM-Gateway

- **Status:** Vorgeschlagen, Gateway-Teil umgesetzt in diesem Change; Paperless ist noch nicht angebunden
- **Datum:** 2026-11-14
- **Freigegeben:** 2026-11-14 (Ingo: LLM-Index gegen `litellm.jit.services`, zunaechst nur der Index)
- **Ergaenzt:** ADR 0006 und ADR 0009 (ein Upstream je Modell, kein Gateway-Fallback, keine Datenbank bleiben)

## Ausgangslage

Paperless-ngx 3.4.2 (seit 13.11.2026) kann einen Vektorindex ueber alle Dokumente
aufbauen ("LLM-Index", sqlite-vec auf der data-PVC). Er braucht nur ein
Embedding-Modell; Vorschlaege und Dokument-Chat brauchen zusaetzlich ein
Chat-Modell und sind nicht Teil dieser Entscheidung.

Der Gateway war bis hierher ein reiner Hermes-Gateway: Ingress nur fuer
`192.168.23.37`, nur `POST /v1/chat/completions` und `GET /v1/models`, zwei
Chat-Modelle, eine Request-Policy fuer Chat-Felder, ein Master-Key.

## Entscheidung

- Drittes Modell `paperless-saia-embedding` (Upstream `openai/qwen3-embedding-4b`
  bei SAIA, derselbe `SAIA_API_KEY`), `mode: embedding`. Dasselbe Modell nutzt
  der Hermes-Wissens-Server direkt (2560 Dimensionen).
- **Paperless spricht den Service direkt an**
  (`http://litellm.litellm.svc.cluster.local:4000/v1`), nicht den Ingress. Die
  CiliumNetworkPolicy erlaubt dem App-Pod (Namespace `paperless-ngx`, Labels
  `app.kubernetes.io/name=paperless-ngx` und `instance=paperless`) auf TCP/4000
  ausschliesslich `POST /v1/embeddings`. Grund: Am Ingress waere nur eine
  Freigabe nach Pod-IP moeglich; die wechselt bei jedem Pod-Start, und eine
  Freigabe des Pod-Netzes gaelte fuer jeden Workload im Cluster.
- Der Ingress bleibt unveraendert. Hermes erreicht `/v1/embeddings` nicht,
  Paperless erreicht weder Chat noch `/v1/models` noch Management-Pfade.
- Die Request-Policy unterscheidet nach `call_type`. Fuer Embeddings gilt ein
  eigener Vertrag: Modell nur `paperless-saia-embedding`, Felder nur `model`,
  `input` (Text oder Liste aus 1 bis 128 nichtleeren Texten) und
  `encoding_format` (`float` oder `base64`). Chat-Modelle sind auf dem
  Embedding-Pfad verboten und umgekehrt. Alles, was kein Embedding-Aufruf ist,
  unterliegt weiter den Chat-Regeln.
- `DEFAULT_MAX_RETRIES=0` am Gateway. `router_settings.num_retries: 0` greift
  bei Embeddings nicht: LiteLLM 1.104.0 macht in `llms/openai/openai.py` aus
  `max_retries=0` den Standard 2 und sendet 429 und 5xx dreimal an den Upstream
  (Vertragstest 14.11.2026). Ein `max_retries: 0` am Deployment aendert das
  nicht, die Umgebungsvariable schon.

## Grenzen und offene Punkte

- **Datenschutz:** Der LLM-Index kennt keinen Tag- oder Besitzerfilter
  (`paperless_ai/indexing.py`: alle Wurzeldokumente). Der Text aller Dokumente,
  auch der mit dem Tag "Privat" und der anderer Benutzer, geht an SAIA (GWDG).
  Fuer Hermes sind Privat-Dokumente ausgenommen; hier ist das nicht moeglich.
- **Ein Schluessel:** Ohne Datenbank kennt LiteLLM nur den Master-Key. Paperless
  bekommt ihn als Secret; die Trennung von Hermes leisten Netzwerk-Policy (Pfad)
  und Request-Policy (Modell), nicht der Schluessel.
- **Kontingent:** SAIA begrenzt je Konto (10/10 s, 400/h, 800/Tag). Ob
  Embeddings dasselbe Kontingent wie Chat belasten, ist nicht gemessen. Der
  Bestand (730 Dokumente, 11,2 Mio. Zeichen) braucht mindestens eine Anfrage je
  Dokument, geschaetzt 750 bis 1000 fuer den Erstaufbau. Bei 429 bricht der
  Index-Task ab und setzt beim naechsten Lauf bei den fehlenden Dokumenten fort.
  Den Erstaufbau deshalb nachts starten; Hermes weicht bei 429 auf Codex aus.
- **Nicht live gegen SAIA geprueft:** Dass SAIA `encoding_format: base64`
  annimmt, das der OpenAI-Client von llama-index sendet, ist nur gegen einen
  Stub getestet. Erste echte Anfrage nach dem Rollout aus dem Paperless-Pod.
- **Unverschluesselt im Cluster:** Paperless -> Gateway laeuft ueber HTTP im
  Pod-Netz, wie schon der Weg Ingress -> Gateway.
- Paperless zeigt mit aktivem Index auch die Chat-Schaltflaeche; ohne
  Chat-Modell endet sie in einem Fehler.

## Rueckweg

Paperless: `PAPERLESS_AI_ENABLED` entfernen, Datei `data/llm_index*` loeschen.
Gateway: diesen Change zuruecknehmen (Modell, Policy-Zweig, Ingress-Regel der
Netzwerk-Policy, `DEFAULT_MAX_RETRIES`, Tests und Pruefskript).
