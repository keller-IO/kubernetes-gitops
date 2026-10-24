# CNPG: `ensure: absent` für Rolle und DB — die Rolle bleibt hängen

## Symptom

Beim Rückbau von gatus-public (PR #372, 23.10.2026) standen im Cluster
`monitoring-pg` gleichzeitig die Managed Role `gatus_public` und das
Database-CR `monitoring-pg-gatus-public` (Owner `gatus_public`) auf
`ensure: absent`. Nach dem Sync war die Datenbank gedroppt, die Rolle aber nicht:

```
$ kubectl -n monitoring-db get cluster.postgresql.cnpg.io monitoring-pg \
    -o jsonpath='{.status.managedRolesStatus.cannotReconcile}'
{"gatus_public":["could not perform DELETE on role gatus_public: owner of database gatus_public\n16 objects in database gatus_public"]}
```

Über eine Stunde später existierte die Rolle noch (`select rolname from pg_roles`),
obwohl ihr nichts mehr gehörte (`pg_shdepend` leer). Die Instanz-Logs zeigten seit
dem Sync keinen weiteren Eintrag „Triggered a managed role reconciliation“.

## Mechanismus

Rollen und Database-CRs gleichen in CNPG zwei getrennte Reconciler ab. Im selben
Sync lief der Rollen-Abgleich vor dem DB-Drop; `DROP ROLE` scheitert, solange der
Rolle die Datenbank gehört. CNPG (1.30.1) wiederholt den Rollen-Abgleich danach
**nicht** zeitgesteuert. Die Rolle bleibt in `pending-reconciliation`, bis sich
`spec.managed.roles` ändert.

## Korrektur

Eine kleine Änderung am Rollen-Eintrag stößt den Abgleich erneut an, hier ein
`comment:` am `gatus_public`-Eintrag (`infrastructure/base/monitoring-db/database.yaml`).
Danach `pg_roles` und `managedRolesStatus` prüfen. Erst wenn die Rolle weg ist,
Rollen-Eintrag, Database-CR und Passwort-Secret entfernen: Ein aus `managed.roles`
entfernter Eintrag wird nicht gedroppt, sondern nur nicht mehr verwaltet.

## Vorbeugung

Rückbau einer CNPG-Datenbank in zwei Schritten:

1. Database-CR auf `ensure: absent` setzen und warten, bis die DB weg ist.
2. Danach die Managed Role auf `ensure: absent` setzen.
3. Erst danach Einträge, CR und Secret löschen.

Beides in einem Commit geht auch, braucht dann aber einen zweiten Anstoß wie
oben. Kein CI-Guardrail: Der Endzustand (Rolle und DB `absent`) ist korrekt,
falsch ist nur die zeitliche Reihenfolge, und die lässt sich statisch nicht prüfen.
