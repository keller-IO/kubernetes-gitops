# EuroOffice: veralteter `settings_error`

## Symptom

Nextcloud meldet per E-Mail "Nextcloud Office Document Server is unavailable", obwohl
`https://eurooffice.jit.services/healthcheck` den Wert `true` liefert und der Document
Server erreichbar ist.

## Ursache

Der EuroOffice-Connector 11.0.1 speichert einen Fehler seines periodischen Editor-Checks
als `eurooffice.settings_error`. Nach einem transienten Fehler, etwa während eines
Document-Server-Restarts, überspringt der Cronjob weitere Prüfungen und löscht den Fehler
nicht selbst. Das Verhalten ist als
[Euro-Office/eurooffice-nextcloud#15](https://github.com/Euro-Office/eurooffice-nextcloud/issues/15)
bekannt; der Fix in
[Pull Request #6](https://github.com/Euro-Office/eurooffice-nextcloud/pull/6) ist noch nicht
veröffentlicht.

## Diagnose und Wiederherstellung

Auf der betroffenen Nextcloud ausführen:

```sh
occ eurooffice:documentserver --check
```

Der Befehl prüft nicht nur `/healthcheck`, sondern auch JWT, Command Service und eine
Testkonvertierung. Bei Erfolg löscht er `settings_error`. Alternativ in den
EuroOffice-Administrationseinstellungen ohne Änderung auf **Save** klicken.

Den gespeicherten Fehler bei Bedarf separat anzeigen:

```sh
occ config:app:get eurooffice settings_error
```

`settings_error` nicht blind leeren: Erst der erfolgreiche vollständige Check bestätigt,
dass URL, JWT-Secret und Rückweg zum Nextcloud-Speicher funktionieren.
