# ADR 0009 - SAIA als Primaerpfad fuer Hermes, Codex bleibt Fallback

- **Status:** Umgesetzt
- **Datum:** 2026-11-11
- **Freigegeben:** 2026-11-11 (Ingo: SAIA-Nutzung fuer Hermes ist erlaubt)
- **Ergaenzt:** ADR 0006 (ein Upstream je Modell, kein Gateway-Fallback bleibt)
- **Loest ab:** das Aktivierungs-Gate aus
  `docs/superpowers/specs/2026-10-20-litellm-saia-qwen-coder-design.md`

## Ausgangslage

Hermes lief seit 18.10.2026 mit `hermes-blablador` als Primaerpfad. Die letzten
15 Talk-Antworten vor dieser Aenderung brauchten meist 130 bis 300 Sekunden,
eine 900 Sekunden. Blablador war damit der Engpass fuer die Nutzbarkeit.

GWDG Academic Cloud (SAIA, `https://chat-ai.academiccloud.de/v1`) lieferte am
11.11.2026 mit `qwen3-coder-next` im direkten Test Antworten in unter einer
Sekunde, bei Streaming, automatischer und erzwungener Werkzeugwahl.

## Entscheidung

- Der Gateway bekommt ein zweites Modell `hermes-saia-qwen-coder` (Upstream
  `openai/qwen3-coder-next`). Es ist freigeschaltet: `MODELS` in
  `request_policy_core.py` enthaelt beide Namen.
- Hermes nutzt `hermes-saia-qwen-coder` als Primaerpfad und weiter
  `openai-codex`/`gpt-5.6-sol` als einzigen Fallback (Ansible, `hermes01`).
- `hermes-blablador` bleibt im Gateway, wird von Hermes aber nicht mehr
  angesprochen. Er ist der Rueckweg, falls SAIA ausfaellt oder die Freigabe endet.
- Weiterhin gilt: ein Deployment je Modell, `num_retries: 0`, kein Fallback und
  kein Load-Balancing im Gateway, keine Datenbank. Den Wechsel zu Codex macht
  Hermes selbst.
- Die Ingress-Allowlist enthaelt nur noch `192.168.23.37` (hermes01 in Potsdam).
  Die alte Adresse `192.168.2.37` ist entfernt, VM 2031 ist geloescht.

## Grenzen

- Der SAIA-Schluessel ist ein persoenlicher Schluessel und liegt nur im
  SOPS-Secret des Clusters. Hermes kennt weiter nur den LiteLLM-Master-Key.
- SAIA begrenzt Anfragen je Konto in Fenstern von 10 Sekunden, einer Stunde und
  einem Tag (`x-ratelimit-*` in den Antwort-Headern). Ist ein Fenster erschoepft,
  antwortet SAIA mit 429, der Gateway reicht das unveraendert durch und Hermes
  wechselt fuer diesen Turn zu Codex. Das Ingress-Limit von 30 Anfragen je Minute
  bleibt deshalb unveraendert.
- Zugelassene Request-Felder sind fuer beide Modelle dieselben
  (`COMMON_CHAT_PARAMETERS`). `reasoning_effort` bleibt verboten.
- Egress: zusaetzlich nur DNS, TCP/443 und SNI fuer `chat-ai.academiccloud.de`.

## Rueckweg

Hermes zurueck auf Blablador: in `host_vars/hermes01.yml`
`hermes_agent_litellm_model: hermes-blablador` setzen und die Rolle ausrollen.
SAIA ganz entfernen: diesen Commit zuruecknehmen (Modell, Secret-Feld,
Umgebungsvariable, FQDN-/SNI-Regeln, Probe und Tests).
