# Rspamd-Ollama: Rollout, Abnahme und Rollback

Dieses Runbook gilt fuer `spam01.jit.land` und `spam02.jit.land`. Beide Hosts
liegen ausserhalb des Kubernetes-Clusters und werden im Repository
`jit/ansible` verwaltet. Die Architekturentscheidung steht in
[ADR 0010](../decisions/0010-rspamd-ollama-integration.md).

## Aktueller Zustand

- `rspamd_ollama_enabled: false` steht in beiden Produktions-Playbooks.
- Alle sieben GPT-Scores sind 0.
- Offline-Contract und Syntaxcheck sind gruen.
- Es gab durch diese Umsetzung keinen produktiven Rollout.
- `spam02` war beim initialen SSH-Preflight nicht erreichbar und bleibt bis zu
  einem erfolgreichen neuen Preflight gesperrt.

Nie beide Scanner gleichzeitig aktivieren. Nach jedem Schritt muss ein
funktionierender Scanner im bisherigen Zustand verbleiben.

## 1. Offline-Vertrag pruefen

Im Ansible-Repository:

```bash
python3 scripts/test-rspamd-ollama.py

syntax_dir="$(mktemp -d)"
touch "$syntax_dir/ansible.cfg"
printf '%s\n' \
  '---' \
  '- hosts: localhost' \
  '  connection: local' \
  '  gather_facts: true' \
  '  roles:' \
  '    - rspamd_ollama' \
  '    - rspamd' >"$syntax_dir/playbook.yml"
ANSIBLE_CONFIG="$syntax_dir/ansible.cfg" \
  ANSIBLE_ROLES_PATH="$PWD/roles" \
  ansible-playbook -i localhost, --syntax-check "$syntax_dir/playbook.yml"
rm -rf "$syntax_dir"
```

Erwartet: 20 bestandene Contract-Tests und ein erfolgreicher Syntaxcheck. Die
leere temporaere Konfiguration vermeidet, dass der reine Offline-Check das
Produktions-Vault-Passwort benoetigt.

## 2. Read-only Preflight je Host

Zuerst `spam01`, spaeter separat `spam02`:

```bash
ansible spam01.jit.land -m ansible.builtin.setup
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'grep -E "^(MemTotal|MemAvailable):" /proc/meminfo'
ansible spam01.jit.land -m ansible.builtin.command -a 'rspamd --version'
```

Freigabebedingungen:

- Debian x86_64, mindestens 4 vCPU und AVX2
- mindestens 10 GiB Gesamt-RAM
- `MemAvailable` mindestens 8 GiB plus 20 Prozent des Gesamt-RAM
- Rspamd mit eingebautem GPT-Modul
- Host stabil erreichbar

Das historische Ergebnis fuer `spam01` ersetzt keinen aktuellen Preflight.
Fuer `spam02` liegt noch kein bestandenes Ergebnis vor.

## 3. Check Mode und Aktivierung eines Scanners

Im versionierten Playbook des Zielhosts nur
`rspamd_ollama_enabled: true` setzen. Alle GPT-Scores bleiben 0. Dann:

```bash
ansible-playbook --check --diff --limit spam01.jit.land playbooks/spam01.yml
ansible-playbook --diff --limit spam01.jit.land playbooks/spam01.yml
```

Keine dauerhafte Aktivierung per `-e` oder uncommitteter Hostvariable. Nach dem
Lauf pruefen:

```bash
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'systemctl is-active ollama'
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'systemctl show ollama -p MemoryMax -p CPUQuotaPerSecUSec'
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'ss -lntp sport = :11434'
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'sha256sum /var/lib/ollama/models/manifests/registry.ollama.ai/library/qwen3/8b'
ansible spam01.jit.land -m ansible.builtin.command -a 'rspamadm configtest'
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'rspamadm configdump gpt'
```

Das Manifest muss SHA-256
`500a1f067a9f782620b40bee6f7b0c89e17ae61f686b92c24933e4ca4b2b8b41`
haben. Ollama darf nur an `127.0.0.1:11434` lauschen. Erwartet sind 8 GiB
`MemoryMax`, 4 CPU-Kerne, GPT-Timeout 20 Sekunden und Rspamd-Task-Timeout 25
Sekunden.

## 4. Warmen Modell-Benchmark ausfuehren

Nur oeffentliche deutsche und englische Ham-/Spam-Korpora verwenden.
Produktionsmails weder kopieren noch als Korpus archivieren. Auf dem aktivierten
Scanner:

```bash
curl --fail --max-time 20 --json \
  '{"model":"qwen3:8b","messages":[],"stream":false,"keep_alive":-1}' \
  http://127.0.0.1:11434/api/chat >/dev/null
mkdir -p /tmp/rspamd-ollama-benchmark/results
for message in /tmp/rspamd-ollama-benchmark/corpus/*.eml; do
  name="$(basename "$message")"
  /usr/bin/time -f '%e' -o "/tmp/rspamd-ollama-benchmark/results/$name.seconds" \
    rspamc -h 127.0.0.1:11333 <"$message" \
    >"/tmp/rspamd-ollama-benchmark/results/$name.rspamd"
done
python3 - <<'PY'
from math import ceil
from pathlib import Path

values = sorted(
    float(path.read_text().strip())
    for path in Path("/tmp/rspamd-ollama-benchmark/results").glob("*.seconds")
)
if not values:
    raise SystemExit("no benchmark timings found")
print(f"count={len(values)} p95={values[ceil(len(values) * 0.95) - 1]:.3f}s max={values[-1]:.3f}s")
PY
```

Manuell die `.rspamd`-Ergebnisse auf parsebare GPT-Wahrscheinlichkeiten im
Bereich 0 bis 1 pruefen. Ein Host besteht nur bei:

- warmem p95 <= 5 Sekunden
- keinem Request > 20 Sekunden
- mindestens 99 Prozent parsebaren Antworten
- mindestens 20 Prozent verbleibender RAM-Reserve
- keinem GPT-beteiligten Task-Timeout

Jedes verfehlte Kriterium stoppt den Rollout. `qwen3:4b` darf nur als separat
gepinnter und vollstaendig neu abgenommener Change getestet werden.

## 5. Shadow Mode beobachten

Alle Scores bleiben mindestens 14 Tage und 100 GPT-Klassifikationen je Scanner
auf 0. Technische Ergebnisse und Latenzen dokumentieren, aber keine
Nachrichteninhalte in ein neues Archiv uebernehmen:

```bash
ansible spam01.jit.land -m ansible.builtin.shell -a \
  'journalctl -u rspamd --since "14 days ago" --no-pager | grep -E "GPT_(SPAM|HAM|MARKETING|PHISHING|SCAM|MALWARE|UNCERTAIN)|task timeout"'
```

Antworten ausserhalb 0 bis 1 gelten als nicht parsebar. Eine Score-Freigabe ist
gesperrt, wenn p99 der Vorpruefungen ueber 5 Sekunden liegt oder ein
Task-Timeout GPT beteiligt.

## 6. SMTP nach DATA abnehmen

Von einem erlaubten Testsystem zwei eindeutig markierte Testmails durch den
regulaeren SMTP-/Milter-Pfad schicken. Beispiel mit einer kontrollierten
Empfaengeradresse:

```bash
: "${RSPAMD_TEST_RECIPIENT:?set a controlled recipient address}"
token="rspamd-ollama-$(date -u +%Y%m%dT%H%M%SZ)"
swaks --server mail.jit-creatives.de \
  --from rspamd-test@jit-creatives.de \
  --to "$RSPAMD_TEST_RECIPIENT" \
  --header "Subject: $token" \
  --header "Message-ID: <$token@jit-creatives.de>" \
  --body "Controlled Rspamd Ollama acceptance message $token"
```

Die SMTP-Sitzung muss `DATA` erfolgreich abschliessen. Den Token in den
Rspamd-Logs korrelieren und belegen, welcher Scanner verarbeitet hat. Wegen des
Round-Robin-Upstreams bei Bedarf mit neuem Token wiederholen, bis beide
Scannerpfade jeweils einmal belegt sind. Keine fremde Adresse und keinen
Produktionsinhalt verwenden.

## 7. GPT_SPAM freigeben

Erst nach bestandenen Gates die Shadow-Ergebnisse manuell pruefen. Nur
`rspamd_gpt_spam_score` darf schrittweise auf hoechstens `3` steigen. Diese
Werte bleiben immer 0:

- `rspamd_gpt_ham_score`
- `rspamd_gpt_marketing_score`
- `rspamd_gpt_phishing_score`
- `rspamd_gpt_scam_score`
- `rspamd_gpt_malware_score`
- `rspamd_gpt_uncertain_score`

Nach jeder Aenderung Contract, Check Mode, echten Lauf und SMTP-Abnahme erneut
ausfuehren. Die GPT-Gruppe muss `max_score = 3` behalten.

## 8. Rollback

1. Alle sieben GPT-Scores auf 0 setzen und das betroffene Playbook ausrollen.
2. Reicht das nicht, `rspamd_ollama_enabled: false` setzen und erneut ausrollen.
3. `systemctl show` muss danach `ActiveState=inactive` und
   `UnitFileState=disabled` melden.
4. `rspamadm configtest` ausfuehren und eine normale SMTP-Zustellung pruefen.

```bash
ansible-playbook --diff --limit spam01.jit.land playbooks/spam01.yml
ansible spam01.jit.land -m ansible.builtin.command \
  -a 'systemctl show ollama -p ActiveState -p UnitFileState'
ansible spam01.jit.land -m ansible.builtin.command -a 'rspamadm configtest'
```

Der Rollback stellt `task_timeout = 8s` wieder her und veraendert weder Redis,
Bayes-Daten noch den bestehenden Nicht-GPT-Filterpfad.

## 9. Evidenz und Betriebskopie

Je Host Datum, Modell-/Manifest-Digest, Korpus-Herkunft, Anzahl, p95, Maximum,
Parse-Quote, RAM-Reserve, Shadow-Zeitraum, Klassifikationszahl und SMTP-Token
festhalten. Keine Prompts, Antworten, Mailtexte oder Empfaengeradressen in Git
committen.

Nach Merge und Freigabe die operative Kopie aktualisieren:

```bash
scp docs/runbooks/rspamd-ollama-integration.md \
  root@192.168.23.19:/root/ansible/kellerio-docs/
```

Dieser Kopierschritt ist keine Rollout-Freigabe und ersetzt nicht die
versionierte Quelle in diesem Repository.
