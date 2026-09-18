# root-app.yaml: Änderungen an der eigenen `include`-Liste greifen nicht automatisch

## Symptom

PR #186 (neue `clusters/main/app-flurfunk.yaml`, in `root-app.yaml`s
`spec.source.directory.include` ergänzt) wurde gemerged, `root` meldete
`Synced/Healthy` auf genau diesem Commit — aber `app-flurfunk` existierte nicht:

```
kubectl get application app-flurfunk -n argocd
Error from server (NotFound): applications.argoproj.io "app-flurfunk" not found
```

## Ursache

`root-app.yaml` definiert die `root`-Application selbst, aber `root`
überwacht laut ihrer eigenen `directory.include`-Liste nur die dort
gelisteten Dateien (`projects.yaml`, `appset-infrastructure.yaml`,
`appset-apps.yaml`, …) — **nicht sich selbst**. Der Datei-Kommentar sagt es
bereits: „Apply once after ArgoCD is installed."

`status.sync.revision` zeigte trotzdem den korrekten, neuesten Merge-Commit
— das bezieht sich nur darauf, dass die *aktuell überwachten* drei/vier
Dateien mit Git übereinstimmen, nicht darauf, dass `root` seine eigene
`.spec` aus Git übernommen hätte. Eine Änderung an `root-app.yaml` selbst
verlangt deshalb immer einen einmaligen manuellen Re-Apply, unabhängig
davon, wie oft ArgoCD den Rest synct.

## Diagnose

```sh
kubectl get application root -n argocd -o jsonpath='{.spec.source.directory.include}'
```

Zeigt die **live** Liste. Stimmt sie nicht mit der Liste in
`clusters/main/root-app.yaml` in Git überein, ist genau das der Grund.

## Behebung

```sh
kubectl apply -f clusters/main/root-app.yaml
```

Danach greift ArgoCDs normale Reconciliation wieder — `app-flurfunk` (bzw.
jede neu ergänzte Datei) wird innerhalb weniger Sekunden angelegt.

## Konsequenz

- Jede PR, die `clusters/main/root-app.yaml` selbst ändert (i. d. R. nur die
  `include`-Liste, wenn eine neue eigenständige `Application` — nicht über
  ein ApplicationSet — hinzukommt), braucht als Merge-Nachbedingung diesen
  manuellen `kubectl apply`. Guardrails/CI können das nicht erzwingen, weil
  es ein Live-Cluster-Schritt ist, keine Git-Prüfung — gehört in die
  PR-Beschreibung als Checklistenpunkt.
- Agenten mit Cluster-Zugriff dürfen das laut
  [Agent-Guardrails](agent-command-guardrails.md) nicht selbst ausführen
  (mutierender `kubectl apply`) — das bleibt ein menschlicher Schritt.
