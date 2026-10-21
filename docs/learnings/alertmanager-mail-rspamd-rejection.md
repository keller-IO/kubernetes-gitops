# Alertmanager-Mail wird trotz erfolgreichem SMTP-Handshake abgewiesen

Am 21.10.2026 um 04:20 UTC war der neue Receiver für `jit-list@jitmail.de`
aktiv. `amtool check-config`, der TLS-Handshake und SMTP-EHLO vom
Alertmanager-Pod waren erfolgreich. Die erste echte Benachrichtigung für
`RecordingRulesNoData` scheiterte dennoch nach `DATA` mit
`554 5.7.1 Spam message rejected`. Zehn unmittelbare Versuche wurden
abgewiesen. Eine spätere Alertmanager-Mail wurde um 13:02 UTC vom Relay
angenommen und per LMTP an die Liste zugestellt; der erste Alarm kam nicht an.

Rspamd bewertete die abgewiesene Nachricht mit **24,62 Punkten bei 15,00
Ablehnungsgrenze**. Der 389 Zeichen lange Standardbetreff mit allen Labels traf
`BAD_SUBJECT_BL` (+13) und `LONG_SUBJ` (+2,92); der fehlende Klartextteil brachte
weitere +2 Punkte. Bayes bewertete den Inhalt zusätzlich als Spam (+5,10).
TLS, DKIM und die Relay-Berechtigung des Cluster-Nodes funktionierten. Eine
globale Lockerung des Spamfilters würde auch fremde Nachrichten betreffen und
ist hier keine passende Korrektur.

Der Alertmanager-Receiver bekommt deshalb einen kurzen Betreff mit Status und
einen Klartextteil mit dem Alertnamen. Nach jedem Wechsel von Empfänger, Template
oder Mailrelay muss die Abnahme **nach `DATA`** erfolgen: in den Alertmanager-
Logs auf SMTP-Fehler und auf dem Relay auf die tatsächliche Annahme und
Weitergabe an `jit-list@jitmail.de` prüfen. Ein EHLO-Test, ein gültiges Zertifikat
oder ein `Synced/Healthy` in ArgoCD beweist keine Zustellung. Der Filter-Score
hängt vom konkreten Alertinhalt und dem veränderlichen Rspamd-Modell ab.
`scripts/ci/check-monitoring.sh` prüft im gerenderten Secret, dass jeder
E-Mail-Receiver einen expliziten kurzen Betreff und Klartext enthält; die
tatsächliche Annahme durch den Relay kann CI nicht garantieren.

Der zugehörige Clusterbefund steht im
[Inspektionsbericht](../runbooks/cluster-inspection-2026-10-20.md).
