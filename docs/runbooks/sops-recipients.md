# Runbook — SOPS-Empfänger ergänzen oder entfernen

Alle Secrets beider Repos (`kubernetes-gitops`, `infrastructure`) sind mit
**age** verschlüsselt. Wer im jeweiligen `.sops.yaml` als Empfänger steht, kann
die Dateien entschlüsseln — jede Änderung an der Empfängerliste muss deshalb
auf **alle** bereits verschlüsselten Dateien nachgezogen werden.

## Aktuelle Empfänger

| Recipient | Gehört zu | Verwendung |
| --- | --- | --- |
| `age17x04ga87qyu9lzcuja9k83z90veew9cez7jusul4y5xyr09xaejs9rq755` | Betriebsschlüssel Ingo **und** Cluster | `~/.config/sops/age/keys.txt`, `sops_age_private_key` in `infrastructure/.../secrets.enc.yaml`, Cluster-Secret `argocd-sops-age` (KSOPS im argocd-repo-server) |
| `age1hjq0mgzc2npw9lhtwr49qqrfvkxzc2ss8qu7e06fk5n84qm7xs7qrgxfxa` | neuer Kollege (seit 18.09.2026) | nur Entschlüsselung am Arbeitsplatz |

Der **erste** Schlüssel ist der, mit dem ArgoCD entschlüsselt. Er darf nie aus
der Liste verschwinden, sonst kann der repo-server nicht mehr rendern und alle
Apps gehen auf `Unknown`/`Degraded`.

## Zwei Stellen, zwei Dateien

| Repo | Konfig | Betroffene Dateien |
| --- | --- | --- |
| `kubernetes-gitops` | `.sops.yaml` (Repo-Wurzel) | alle `*.sops.yaml` (32 Stück, Stand 18.09.2026) |
| `infrastructure` | `tofu/talos-cluster/envs/kellerIO/.sops.yaml` | `secrets.enc.yaml` — **nicht im Git**, liegt nur lokal; muss dem neuen Empfänger separat übergeben werden |

## Ablauf

1. Öffentlichen age-Key des neuen Empfängers besorgen (`age-keygen -y < keys.txt`,
   Format `age1…`, 62 Zeichen). Der private Key bleibt bei ihm.
2. Key in beiden `.sops.yaml` an die `age:`-Liste anhängen (kommagetrennt,
   Reihenfolge egal — ArgoCD-Key stehen lassen).
3. Bestehende Dateien neu verschlüsseln. Das geht nur mit einem Key, der die
   Dateien **heute schon** lesen kann:

   ```sh
   export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

   cd ~/ansible/kubernetes-gitops
   find . -path ./.git -prune -o -name '*.sops.yaml' -print | grep -v '^\./\.sops\.yaml$' \
     | xargs -n1 sops updatekeys -y

   cd ~/ansible/infrastructure/tofu/talos-cluster/envs/kellerIO
   sops updatekeys -y secrets.enc.yaml
   ```

   `updatekeys` tauscht nur die Schlüssel-Stanzas, der Ciphertext der Werte
   bleibt byte-gleich — im Diff dürfen nur `sops:`-Blöcke auftauchen.
4. Gegenprobe: pro Datei muss **jedes** YAML-Dokument beide Empfänger führen
   (Dateien wie `mastodon/secret.sops.yaml` enthalten mehrere Dokumente, also
   auch mehrere `sops:`-Blöcke), und der Klartext muss unverändert sein:

   ```sh
   diff <(git show origin/main:<datei> | sops -d /dev/stdin) <(sops -d <datei>)
   ```
5. PR mergen. ArgoCD braucht **keinen** Eingriff: sein Key ist weiterhin
   Empfänger, die Secrets rendern unverändert.

## Was das Ergänzen NICHT leistet

- **Kein Rotieren.** Ein entfernter Empfänger kann jeden alten Commit weiterhin
  entschlüsseln — die Git-Historie enthält die mit seinem Key verschlüsselten
  Fassungen. Wer wirklich ausgesperrt werden soll, braucht neue Werte in den
  Secrets (Passwörter, Tokens, TSIG-Keys) und den Tausch der betroffenen
  Zugänge, nicht nur ein `updatekeys`.
- **Kein Cluster-Zugang.** Entschlüsseln ≠ bedienen. Dafür zusätzlich nötig:
  `kubeconfig`/`talosconfig` aus `infrastructure/tofu/talos-cluster/envs/kellerIO/`,
  Git-Schreibrecht auf beide Repos und ein Keycloak-Konto in der ArgoCD-Gruppe.
