# Mastodon: Spam-Anmeldungen nutzen jit.social als Mailversender

Stand 25.10.2026. Aufgefallen beim Upgrade auf 4.7.3 (#386).

## Symptom

Nach dem Upgrade gab es 628 lokale Accounts statt 732 wie wenige Stunden vorher
und auf dem Restore-Klon. Das sah nach Datenverlust durch eine Migration aus.
Keine Migration von 4.7.3 löscht aber lokale Accounts, und jeder verbliebene
lokale Account hatte seinen `#main-key`.

Die Ursache zeigte die Tabelle `users`:

```sql
select approved, confirmed_at is not null as confirmed, count(*) from users group by 1, 2;
-- f | f | 558   unbestätigt, nicht freigegeben
-- f | t |   8
-- t | t |  60
```

- 539 Anmeldungen seit dem 22.09.2026 tragen als Begründung wörtlich
  „Automated protocol deliverability probe“.
- Die Adressen liegen überwiegend bei iCloud (400) und Gmail (91), dazu kommen
  japanische Mobilfunk-Domains (ezweb.ne.jp, au.com, docomo.ne.jp).
- Die Anmeldungen kommen von 537 verschiedenen IPs, 557 mit `locale=en`.
- Am 19.10. waren es 152 Anmeldungen, am 20.10. 116. Seit dem 24.10. ist es
  etwa eine pro Stunde.

## Mechanismus

- Die Registrierung steht auf Freigabe (`registrations_mode = approved`,
  Begründung Pflicht). Die Konten können nichts tun. Mastodon verschickt die
  **Bestätigungsmail aber sofort bei der Anmeldung**, vor jeder Freigabe, über
  `mail.jit-creatives.de` als `notifications@jit.social`. Das Formular wird so
  zum Mailversender an fremde Adressen. Das gefährdet den Ruf des Mailservers.
- Die Admins bekommen die Mail zu einem neuen Konto erst nach der Bestätigung
  (`User#after_confirmation_tasks` → `notify_staff_about_pending_account!`),
  also nur bei den wenigen bestätigten Konten.
- `Scheduler::UserCleanupScheduler` löscht unbestätigte User 7 Tage nach
  `confirmation_sent_at`, Account und User per `delete_all`. Die Uhrzeit
  würfelt Mastodon bei jedem Start des Scheduler-Pods neu aus (04:00–06:59
  UTC). Die Zahl lokaler Accounts schwankt deshalb jeden Tag um die Zahl der
  Spam-Anmeldungen von vor einer Woche. Am 25.10. lief der Cleanup im alten
  Scheduler-Pod zwischen der Zählung um 05:20 und dem Rollout um 08:02.
- Echte Anmeldungen gibt es kaum: In 90 Tagen wurde niemand freigegeben, im
  letzten Jahr 4 Konten.

## Korrektur

Offen, die Entscheidung liegt bei den Admins von jit.social. Die Einstellungen
liegen in der Datenbank (`settings`), nicht in GitOps.

- Wirksam und einfach: Registrierung schließen (Administration →
  Servereinstellungen → Registrierungen → „Niemand kann sich registrieren“).
  Einladungen durch Admins bleiben möglich (`min_invite_role = admin`). Das
  Formular verschickt dann keine Mails mehr.
- Schwächer: E-Mail-Domain-Sperren für die japanischen Mobilfunk-Domains.
  iCloud und Gmail lassen sich nicht sperren, ohne echte Nutzer zu treffen.
  IP-Sperren helfen bei 537 IPs nicht.
- hCaptcha würde die Bots bremsen, bindet aber einen externen Dienst ein.
- Die wartenden Konten muss niemand ablehnen, der Cleanup löscht unbestätigte
  nach 7 Tagen. Die 8 bestätigten, nicht freigegebenen Konten in der
  Moderation prüfen, darunter sind 3 mit dem Probe-Text.

## Prävention

- Vor- und Nachher-Zählungen bei Upgrades vergleichen lokale Accounts mit
  ihren Schlüsseln **zum selben Zeitpunkt**, nicht mit einer Zählung von
  früher (Runbook `mastodon-migration.md`, Upgrade-PR, Schritt 5).
- Unbestätigte Anmeldungen im Blick behalten:
  `select confirmation_sent_at::date, count(*) from users where confirmed_at is null group by 1 order by 1 desc limit 10`.
  Ein CI-Guardrail passt nicht, weil die Einstellung live in der Datenbank
  liegt.
