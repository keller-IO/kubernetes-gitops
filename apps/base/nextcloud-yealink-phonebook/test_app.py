import os
import unittest
import xml.etree.ElementTree as ET


os.environ.update(
    {
        "NEXTCLOUD_URL": "https://nextcloud.example",
        "NEXTCLOUD_USERNAME": "test@example.com",
        "NEXTCLOUD_APP_PASSWORD": "secret",
        "PHONEBOOK_TOKEN": "token",
    }
)

import app


class VCardTests(unittest.TestCase):
    def test_parses_folded_and_quoted_printable_names(self):
        vcard = """BEGIN:VCARD\r
VERSION:2.1\r
FN;CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE:J=C3=B6rg =\r
M=C3=BCller\r
TEL;TYPE=CELL:+49 170 1234567\r
END:VCARD\r
"""

        contacts = app.parse_vcards(vcard)

        self.assertEqual(
            contacts,
            [app.Contact("Jörg Müller", ("+491701234567",))],
        )

    def test_does_not_append_tel_uri_extension(self):
        vcard = """BEGIN:VCARD
VERSION:4.0
FN:Support
TEL;VALUE=uri:tel:+49-30-123;ext=45
END:VCARD
"""

        contacts = app.parse_vcards(vcard)

        self.assertEqual(contacts, [app.Contact("Support", ("+4930123",))])

    def test_renders_escaped_yealink_xml(self):
        xml = app.render_phonebook([app.Contact("Müller & Partner", ("+4930123", "42"))])
        root = ET.fromstring(xml)

        self.assertEqual(root.tag, "YealinkIPPhoneDirectory")
        self.assertIsNone(root.find("Title"))
        self.assertIsNone(root.find("Prompt"))
        self.assertEqual(root.findtext("DirectoryEntry/Name"), "Müller & Partner")
        self.assertEqual(
            [element.text for element in root.findall("DirectoryEntry/Telephone")],
            ["+4930123", "42"],
        )


if __name__ == "__main__":
    unittest.main()
