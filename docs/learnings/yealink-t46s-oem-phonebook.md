# Yealink T46S: OEM-Firmware blockiert Remote Phone Book

## Symptom

Das T46S `192.168.9.150` mit Firmware `66.85.193.13` lud das vom
Kubernetes-Dienst erzeugte Remote-Telefonbuch erfolgreich per HTTP 200. Trotzdem
fehlte `Remote Phone Book` auf dem Display. Die Weboberfläche zeigte die Quelle
als aktiviert und behielt diese Einstellung auch nach Neustarts bei.

## Ursache

Der OEM-Build zeigt die Yealink-V85-Einstellungen in der Weboberfläche, übernimmt
sie aber nicht vollständig in die aktive Telefonanwendung:

- `directory_setting.remote_phone_book.*` wurde beim CFG-Import verworfen.
- Der native DSS-Typ 22 mit `xml_phonebook = 0` blieb ohne Funktion.
- Der generische XML-Browser ist kein Ersatz für den nativen Remote-Phone-Book-
  Parser und meldete bei diesem Modell `File Layout Error`.
- `local_contact.data.url` aus einem lokal importierten CFG wurde ebenfalls
  verworfen. Ein testweise aktivierter täglicher Auto-Provision-Lauf rief den
  Kontakt-Endpunkt nicht ab und wurde deshalb wieder deaktiviert.

## Funktionierender Fallback

Der Dienst stellt zusätzlich zum Remote-Format ein T46S-Lokalformat unter dem
tokenisierten Pfad `local-directory.xml` bereit. Das Legacy-Format besteht aus
zwei aufeinanderfolgenden Wurzelelementen `root_group` und `root_contact`.

Die Datei wurde einmalig in der Telefon-Weboberfläche unter
`Directory > Local Directory > Import XML` importiert. Der anschliessende
Geräteexport enthielt 17 Kontakte. Auf dem Display sind sie erreichbar über:

```text
Kontakte > Alle Kontakte > Eingeben
```

`Alle Kontakte` ist eine Gruppenauswahl und noch nicht die Kontaktliste. Erst
`Eingeben` beziehungsweise die mittlere OK-Taste öffnet die Einträge.

Die untere programmierbare Taste `Kontakte` verwendet wieder den nativen
Directory-Typ 61. Die erfolglose zusätzliche Display-Taste wurde auf ihre
ursprüngliche Line-Key-Konfiguration zurückgesetzt.

## Aktualisierung und Rollback

Nextcloud wird im Cluster weiterhin alle 15 Minuten gelesen. Wegen der
OEM-Sperre aktualisiert sich die lokale Kopie auf dem Telefon jedoch nicht
automatisch. Nach relevanten Nextcloud-Änderungen muss `local-directory.xml`
erneut über die Weboberfläche importiert werden. Eine echte Automatisierung
erfordert Kontrolle über den von PnP/DHCP gelieferten Provisionierungsserver
oder einen gesonderten, getesteten Web-Upload-Client.

Der vor dem Import erzeugte Local-Directory-Export war leer und liegt unter:

```text
/home/ingo/ansible/backups/yealink-805ec0dc9270-contact-before-nextcloud-20260728.xml
```

Ein XML-Import ersetzt das lokale Telefonbuch vollständig. Vor jedem späteren
Import daher erneut exportieren, falls lokale Kontakte am Telefon ergänzt wurden.
