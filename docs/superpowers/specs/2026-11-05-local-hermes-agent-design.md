# Local Hermes Agent Design

## Ziel

Hermes Agent laeuft auf dem aktuellen openSUSE-Tumbleweed-Rechner als
terminalbasierter Assistent. Ein lokales 27B-Modell ist der Primaerpfad. GWDG
SAIA und Blablador sind explizite Ausweichprovider in dieser Reihenfolge. Vom
Agenten erzeugte Shell-, Datei- und Code-Ausfuehrungen laufen in einer rootless
Podman-Sandbox.

Die vorhandene produktive Hermes-, LiteLLM- und Blablador-Konfiguration auf
anderen Systemen bleibt unveraendert. Diese Einrichtung aendert weder
Kubernetes-Ressourcen noch den Live-Cluster.

## Komponenten und Datenfluss

Hermes wird mit dem offiziellen stabilen CLI-Installer unter `~/.hermes`
installiert. Browser- und Computer-Use-Komponenten bleiben aus. Hermes selbst
laeuft auf dem Host, damit sein verwalteter `llama.cpp`-Prozess die lokale
AMD-iGPU ueber Vulkan verwenden kann. Nur Agentenwerkzeuge laufen im Container.

Das Primaermodell ist
`Qwen3.8-27B-UD-Q4_K_M.gguf` aus `unsloth/Qwen3.8-27B-GGUF`. Die Q4_K_M-Datei
ist etwa 16,5 GB gross, hat 262K nativen Kontext und wird von Hermes v0.22.7 als
bestes universelles Agentenmodell im verwalteten lokalen Katalog gefuehrt. Sie
wird als einzelne GGUF-Datei nach `~/.hermes/models/` geladen. Hermes erkennt
vollstaendige GGUF-Dateien in diesem maschinenweiten Verzeichnis, installiert
seinen gepinnten `llama.cpp`-Vulkan-Engine und verwaltet Serverstart,
Speicherplatzierung und Entladen. Der Hauptprovider ist `llamacpp`; die
Modell-ID ist der Dateiname ohne `.gguf`.

Zwei benannte OpenAI-kompatible Provider werden unter `providers:` angelegt:

- `custom:saia` verwendet `https://chat-ai.academiccloud.de/v1` mit
  `qwen3-coder-next`.
- `custom:blablador` verwendet
  `https://api.blablador.fz-juelich.de/v1` mit `alias-code`.

Die Hauptkette lautet:

1. `llamacpp:Qwen3.8-27B-UD-Q4_K_M`
2. `custom:saia:qwen3-coder-next`
3. `custom:blablador:alias-code`

Jeder neue Nutzerturn beginnt wieder mit dem lokalen Modell. Hermes aktiviert
innerhalb eines Turns hoechstens einen Fallback. Wenn SAIA nach einer
erfolgreichen Umschaltung selbst ausfaellt, wird Blablador in diesem Turn nicht
mehr aufgerufen. Blablador kann als dritter Eintrag genutzt werden, wenn SAIA
bereits bei der Kandidatenaufloesung nicht verfuegbar ist, und bleibt ausserdem
manuell waehlbar. Eine strikt kaskadierende Drei-Provider-Garantie ist ohne den
bewusst abgelehnten zusaetzlichen Router nicht Bestandteil dieses Designs.

Hilfsaufgaben bleiben auf `provider: auto`. Sie versuchen damit zuerst das
Hauptmodell und folgen nur der ausdruecklich konfigurierten Fallback-Politik.
Hermes darf nicht auf zufaellig vorhandene andere Provider-Logins ausweichen.

## Kontext und Werkzeuge

Qwen3.8-27B hat 262K nativen Kontext und ist fuer Tool-Calling ausgelegt. Fuer
eine kleine, kontrollierbare Angriffs- und Promptflaeche aktiviert die erste
CLI-Konfiguration trotzdem nur:

- `terminal`
- `file`
- `web`
- `skills`
- `todo`
- `memory`
- `session_search`
- `clarify`

Browser, Bildgenerierung, Cron, Messaging, Code-Delegation und weitere
Toolsets bleiben zunaechst aus. Das reduziert den Systemprompt und laesst mehr
Kontext fuer Repositories und Tool-Ergebnisse. Weitere Toolsets koennen nach
einem erfolgreichen Basistest mit `hermes tools` aktiviert werden.

## Podman-Sandbox

Hermes verwendet den Docker-kompatiblen Terminal-Backend mit
`HERMES_DOCKER_BINARY=podman`. Podman laeuft rootless. Das aktuelle
Hermes-Standard-Sandbox-Image wird verwendet, damit Image und Hermes-Version
kompatibel bleiben.

Die Sandbox bekommt acht CPU-Kerne und 16 GiB RAM. Ein explizites
Overlay-Disk-Limit wird nicht gesetzt, weil dessen Unterstuetzung vom lokalen
Podman-Storage-Treiber abhaengt. Der Container und sein `/workspace` bleiben
ueber Hermes-Prozesse und Sitzungen hinweg erhalten.

`docker_mount_cwd_to_workspace: true` bindet das Verzeichnis, aus dem Hermes
gestartet wurde, nach `/workspace` ein. Dies ist der einzige allgemeine
Host-Arbeitsbereich. Hermes v0.22.7 bindet zusaetzlich sein persistentes,
containerprivates Sandbox-Home unter `/root` schreibbar sowie seine eigenen
Skill-, Attachment- und Cache-Staging-Verzeichnisse unter `/root/.hermes`
read-only ein. Diese Support-Mounts sind in dieser Version nicht per
Konfiguration abschaltbar. Die Master-Stores `.env` und `auth.json` sind im
Upstream explizit von Credential-Mounts ausgeschlossen; neue skillspezifische
Credential-Dateien beduerfen einer eigenen Sicherheitspruefung.

Die Sandbox sieht damit nicht pauschal das restliche Home-Verzeichnis,
SSH-Schluessel oder Kubernetes-Konfiguration. Der Workspace-Mount ist
schreibbar; ein destruktiver Agentenbefehl kann daher uncommittete Aenderungen
im Arbeitsbereich zerstoeren. Git bleibt die Wiederherstellungsgrenze.

Netzwerkzugriff bleibt fuer Paketquellen, Git und externe Dokumentation aktiv.
Damit kann ein kompromittierter Prozess grundsaetzlich Inhalte des gemounteten
Arbeitsbereichs, des Sandbox-Homes und der Hermes-eigenen read-only
Support-Mounts nach aussen senden. Provider- und Master-Geheimnisse werden
deshalb nicht in den Container gereicht: `docker_forward_env` und
`env_passthrough` bleiben leer, und die aktuelle Mountliste enthaelt keine
Credential-Datei.

Hermes ueberspringt gefaehrliche Shell-Kommandoabfragen bei Container-Backends,
weil der Container die Schutzgrenze ist. Diese Grenze schuetzt nicht den
schreibbar eingebundenen Arbeitsbereich.

## Geheimnisse

`SAIA_API_KEY` und `BLABLADOR_API_KEY` liegen ausschliesslich in
`~/.hermes/.env` mit Modus `0600`. `config.yaml` enthaelt nur die Namen der
Umgebungsvariablen unter `key_env`. Schluesselwerte duerfen weder in
Kommandoargumenten noch in Ausgaben, Logs oder Shell-History erscheinen.

Der vorhandene SAIA-Schluessel wird aus der bereits gesetzten Prozessumgebung
uebernommen. Der Blablador-Schluessel wird aus
`/home/ingo/ansible/apikey.env` uebernommen, ohne den Wert auszugeben. Die
Provider-Aufrufe erfolgen im Hermes-Hostprozess; die Podman-Sandbox benoetigt
keinen der beiden Schluessel.

Beide Werte sind ausdruecklich nur Test-Tokens. Nach einer unbeabsichtigten
Ausgabe in isoliertem Reviewer-Tool-Output hat der Nutzer die weitere Nutzung
ohne Rotation als akzeptiertes Risiko eingestuft. Diese einmalige Entscheidung
aendert nicht die allgemeine Vorgabe, Tokenwerte in kuenftigen Befehlen,
Ausgaben und Logs zu unterdruecken.

## Fehlerverhalten

Hermes verwendet einen App-Level-Versuch pro Providerroute und keine
zusaetzliche Auto-Recovery-Schleife. Dadurch blockiert ein defektes lokales
Backend nicht lange, bevor der Fallback aktiviert wird. SAIA und Blablador
erhalten explizite Request- und Stale-Timeouts. Der Hermes-Runtime-Supervisor
behandelt den Start und die Modellladezeit des lokalen Servers.

Die expliziten Modellwechsel
`/model custom:saia:qwen3-coder-next` und
`/model custom:blablador:alias-code` bleiben fuer Diagnose und bewusste
Ausweichnutzung verfuegbar.

## Umsetzung und Abnahme

Vor der ersten Aenderung werden vorhandene `~/.hermes`-Konfigurationsdateien
gesichert, falls zwischen Design und Umsetzung eine Installation entstanden
ist. Die Umsetzung gilt erst als abgenommen, wenn folgende Pruefungen
erfolgreich sind:

1. `hermes doctor` und `hermes config check` melden keine
   Konfigurationsfehler.
2. Die Podman-Sandbox sieht das Startverzeichnis als `/workspace`, ihr
   Hermes-verwaltetes Sandbox-Home und die dokumentierten Hermes-eigenen
   read-only Support-Mounts, aber keine anderen Hostpfade, Credential-Dateien
   oder Provider-Schluessel.
3. Das lokale Modell beantwortet einen kurzen Prompt, fuehrt einen begrenzten
   Tool-Call aus und verwendet den Vulkan-Backend mit der erwarteten Modell-ID.
4. SAIA besteht einen direkten minimalen Chat- und Tool-Calling-Test mit
   `qwen3-coder-next`.
5. Blablador besteht einen direkten minimalen Chat- und Tool-Calling-Test mit
   `alias-code`.
6. Bei einem echten Request-Fehler des aktiven lokalen Servers wechselt Hermes
   automatisch zu SAIA. Das administrative Deaktivieren der lokalen Runtime
   ist in v0.22.7 ein Konfigurationsfehler und kein gueltiger Fallback-Test.
   Nach Behebung des Serverfehlers verwendet ein neuer Turn wieder das lokale
   Modell.

Eine SAIA-zu-Blablador-Kaskade nach einem bereits aktivierten SAIA-Fallback
wird wegen der dokumentierten Ein-Fallback-pro-Turn-Grenze nicht behauptet.
Blablador wird stattdessen direkt abgenommen.

## Rollback

Ein Konfigurationsrollback stellt die vor der Umsetzung gesicherten
`~/.hermes/config.yaml`- und `.env`-Dateien wieder her. Das lokale Modell und
der Runtime-Download sind reine Benutzerdateien unter `~/.hermes`; ihre
Entfernung ist vom Konfigurationsrollback getrennt, damit ein erneuter Versuch
keinen mehrgigrossen Download erzwingt. Podman-Sandbox und Modellartefakte
werden nur auf ausdruecklichen Wunsch geloescht.

Ein vollstaendiger Host-Rollback entfernt ausserdem den instanzspezifischen
systemd-Drop-in fuer `user@1000.service`, laedt die systemd-Konfiguration neu
und wird in einer neuen Login-Sitzung wirksam.
`render`-Gruppenmitgliedschaft, die aktuelle Device-ACL und
`LLAMA_ARG_N_PARALLEL=1` werden separat und nur bewusst zurueckgenommen, weil
sie auch andere lokale GPU-Nutzung beeinflussen beziehungsweise die
beobachtete Vulkan-Instabilitaet wieder aktivieren koennen.
