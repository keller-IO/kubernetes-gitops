# Roundcube: pgloader erzeugt inkompatible PostgreSQL-Typen

## Symptom

Roundcube zeigt unter Einstellungen keine Identitaeten und im Adressbuch keine
Kontakte. Im Pod-Log stehen Fehler wie:

```text
operator does not exist: boolean <> integer
permission denied for table collected_addresses
```

Die Datensaetze sind weiterhin vorhanden; die Abfrage bricht vor der Anzeige ab.

## Ursache

Der historische MySQL-zu-PostgreSQL-Job liess pgloader die Zieltabellen mit
`include drop` und `create tables` selbst erzeugen. pgloader bildet MySQL
`tinyint(1)` automatisch auf PostgreSQL `boolean` ab. Roundcubes natives
PostgreSQL-Schema verwendet fuer Core-Flags wie `identities.del`,
`identities.standard`, `contacts.del`, `contactgroups.del` und
`cache_index.valid` jedoch `smallint`; die Anwendung vergleicht sie mit `0`
oder `1`.

Spaetere Roundcube-Schema-Updates legten ausserdem Tabellen als PostgreSQL-Admin
statt als App-Rolle an. Dadurch fehlten `roundcube` die Rechte auf
`collected_addresses`, `responses` und `filestore` samt Sequenzen.

## Diagnose und Reparatur

Vor der Reparatur die Datensaetze in Quelle und Ziel zaehlen und ein CNPG-Backup
erstellen. Die am 27.07.2026 verwendete transaktionale Reparatur liegt unter
`apps/base/roundcube/postgres-schema-repair-20260727.sql`.

```sh
kubectl exec -i -n roundcube roundcube-pg-1 -- \
  psql -d roundcube < apps/base/roundcube/postgres-schema-repair-20260727.sql
```

Bei kuenftigen Migrationen zuerst Roundcubes natives PostgreSQL-Schema anlegen
und nur Daten importieren. pgloader darf die Zieltabellen nicht automatisch aus
den MySQL-Typen ableiten. Nach Roundcube-Schema-Updates zusaetzlich Owner und
Rechte neu angelegter Tabellen pruefen.
