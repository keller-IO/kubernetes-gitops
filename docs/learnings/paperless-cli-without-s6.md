# Paperless-CLI ausserhalb von s6

## Beobachtung

Der einmalige Export-Job fuer das Upgrade auf Paperless 2.20.15 startete
`/usr/local/bin/document_exporter` direkt und brach sofort ab:

```text
s6-envdir: fatal: unable to envdir /run/s6/container_environment: No such file or directory
```

ArgoCD stoppte wegen `backoffLimit: 0` vor den nachgelagerten Backup- und
Snapshot-Wellen. Paperless blieb dadurch wie vorgesehen quiesziert.

## Ursache

`document_exporter` ist im offiziellen Container kein eigenstaendiges Binary,
sondern ein Skript mit `#!/command/with-contenv`. Das Verzeichnis
`/run/s6/container_environment` wird erst vom regulaeren Entrypoint `/init`
angelegt. Ein Kubernetes-Job, der den Wrapper als eigenes `command` verwendet,
umgeht `/init` und kann den s6-Environment-Wrapper deshalb nicht benutzen.

## Robustes Muster

Ein One-shot-Job ruft den Django-Management-Befehl ohne den s6-Wrapper auf,
setzt das Image-Arbeitsverzeichnis explizit und wechselt auf den normalen
Paperless-Benutzer:

```yaml
workingDir: /usr/src/paperless/src
command: [/command/s6-setuidgid]
args:
  - paperless
  - python3
  - manage.py
  - document_exporter
  - /usr/src/paperless/export/<ziel>
```

Die benoetigten `PAPERLESS_*`-Variablen und Secrets muessen der Job-Spec direkt
uebergeben werden. Bei einer Korrektur muss der Job einen neuen Namen erhalten,
weil `spec.template` eines bestehenden Kubernetes-Jobs immutable ist.
