import base64
import hmac
import json
import logging
import os
import quopri
import re
import threading
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


MAX_CARDDAV_RESPONSE = 20 * 1024 * 1024
NEXTCLOUD_URL = os.environ["NEXTCLOUD_URL"].rstrip("/")
ADDRESSBOOK = os.environ.get("ADDRESSBOOK", "contacts")
REFRESH_INTERVAL = int(os.environ.get("REFRESH_INTERVAL", "900"))
PORT = int(os.environ.get("PORT", "8080"))
SECRET_DIRECTORY = os.environ.get("SECRET_DIRECTORY", "/run/secrets/phonebook")


@dataclass(frozen=True)
class Contact:
    name: str
    numbers: tuple[str, ...]


class PhonebookState:
    def __init__(self):
        self.lock = threading.Lock()
        self.xml = None
        self.local_directory_xml = None
        self.contact_count = 0
        self.last_success = None
        self.last_success_monotonic = None
        self.last_error = None


state = PhonebookState()


def secret_value(filename, environment_name):
    environment_value = os.environ.get(environment_name)
    if environment_value is not None:
        return environment_value
    with open(os.path.join(SECRET_DIRECTORY, filename), encoding="utf-8") as secret_file:
        return secret_file.read().strip()


def split_escaped(value, separator):
    parts = []
    current = []
    escaped = False
    for char in value:
        if escaped:
            current.extend(("\\", char))
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == separator:
            parts.append("".join(current))
            current = []
        else:
            current.append(char)
    if escaped:
        current.append("\\")
    parts.append("".join(current))
    return parts


def unescape_vcard(value):
    return re.sub(
        r"\\([nN,;\\])",
        lambda match: "\n" if match.group(1).lower() == "n" else match.group(1),
        value,
    ).strip()


def decode_property(value, parameters):
    encoding = parameters.get("ENCODING", "").upper()
    if encoding == "QUOTED-PRINTABLE":
        charset = parameters.get("CHARSET", "utf-8")
        value = quopri.decodestring(value).decode(charset, errors="replace")
    return value


def parse_property(line):
    if ":" not in line:
        return None
    descriptor, value = line.split(":", 1)
    descriptor_parts = descriptor.split(";")
    name = descriptor_parts[0].rsplit(".", 1)[-1].upper()
    parameters = {}
    bare_parameters = []
    for parameter in descriptor_parts[1:]:
        if "=" in parameter:
            key, parameter_value = parameter.split("=", 1)
            parameters[key.upper()] = parameter_value.strip('"')
        else:
            bare_parameters.append(parameter)
    if bare_parameters:
        parameters["TYPE"] = ",".join(bare_parameters)
    return name, parameters, decode_property(value, parameters)


def unfold_vcard(text):
    unfolded = []
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        if line.startswith((" ", "\t")) and unfolded:
            unfolded[-1] += line[1:]
        elif (
            unfolded
            and "ENCODING=QUOTED-PRINTABLE" in unfolded[-1].partition(":")[0].upper()
            and unfolded[-1].endswith("=")
        ):
            unfolded[-1] = unfolded[-1][:-1] + line
        else:
            unfolded.append(line)
    return unfolded


def normalize_number(value):
    value = unescape_vcard(value)
    if value.lower().startswith("tel:"):
        value = value[4:]
    value = re.split(r"(?i)(?:;ext=|\b(?:ext|extension|x)\.?\s*)", value, maxsplit=1)[0]
    return "".join(char for char in value if char in "0123456789+*#")


def parse_vcards(text):
    contacts = []
    properties = []
    in_vcard = False

    for line in unfold_vcard(text):
        if line.upper() == "BEGIN:VCARD":
            properties = []
            in_vcard = True
            continue
        if line.upper() == "END:VCARD" and in_vcard:
            parsed = contact_from_properties(properties)
            if parsed:
                contacts.append(parsed)
            in_vcard = False
            continue
        if in_vcard:
            property_value = parse_property(line)
            if property_value:
                properties.append(property_value)
    return contacts


def contact_from_properties(properties):
    full_name = ""
    structured_name = ""
    organization = ""
    numbers = []

    for name, _parameters, value in properties:
        if name == "FN" and not full_name:
            full_name = unescape_vcard(value)
        elif name == "N" and not structured_name:
            parts = [unescape_vcard(part) for part in split_escaped(value, ";")]
            parts += [""] * (5 - len(parts))
            family, given, additional, prefix, suffix = parts[:5]
            structured_name = " ".join(
                part for part in (prefix, given, additional, family, suffix) if part
            )
        elif name == "ORG" and not organization:
            organization = " ".join(
                unescape_vcard(part)
                for part in split_escaped(value, ";")
                if unescape_vcard(part)
            )
        elif name == "TEL":
            number = normalize_number(value)
            if number and number not in numbers:
                numbers.append(number)

    display_name = full_name or structured_name or organization
    if not display_name or not numbers:
        return None
    return Contact(display_name, tuple(numbers[:3]))


def carddav_url(username):
    username = urllib.parse.quote(username, safe="")
    addressbook = urllib.parse.quote(ADDRESSBOOK, safe="")
    return f"{NEXTCLOUD_URL}/remote.php/dav/addressbooks/users/{username}/{addressbook}/"


def fetch_contacts():
    query = b"""<?xml version="1.0" encoding="UTF-8"?>
<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
  <d:prop>
    <d:getetag/>
    <card:address-data content-type="text/vcard">
      <card:prop name="FN"/><card:prop name="N"/><card:prop name="ORG"/><card:prop name="TEL"/>
    </card:address-data>
  </d:prop>
  <card:filter/>
</card:addressbook-query>
"""
    username = secret_value("nextcloud-username", "NEXTCLOUD_USERNAME")
    app_password = secret_value("nextcloud-app-password", "NEXTCLOUD_APP_PASSWORD")
    credentials = base64.b64encode(
        f"{username}:{app_password}".encode()
    ).decode()
    request = urllib.request.Request(
        carddav_url(username),
        data=query,
        method="REPORT",
        headers={
            "Authorization": f"Basic {credentials}",
            "Content-Type": "application/xml; charset=utf-8",
            "Depth": "1",
            "User-Agent": "nextcloud-yealink-phonebook/1.0",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = response.read(MAX_CARDDAV_RESPONSE + 1)
    if len(payload) > MAX_CARDDAV_RESPONSE:
        raise ValueError("CardDAV response exceeds 20 MiB limit")

    root = ET.fromstring(payload)
    contacts = []
    for element in root.iter("{urn:ietf:params:xml:ns:carddav}address-data"):
        contacts.extend(parse_vcards(element.text or ""))

    unique = {(contact.name.casefold(), contact.numbers): contact for contact in contacts}
    return sorted(unique.values(), key=lambda contact: contact.name.casefold())


def render_phonebook(contacts):
    root = ET.Element("YealinkIPPhoneDirectory")
    for contact in contacts:
        entry = ET.SubElement(root, "DirectoryEntry")
        ET.SubElement(entry, "Name").text = contact.name
        for number in contact.numbers:
            ET.SubElement(entry, "Telephone").text = number
    ET.indent(root, space="  ")
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)


def render_local_directory(contacts):
    groups = ET.Element("root_group")
    ET.SubElement(groups, "group", display_name="All Contacts", ring="")
    ET.SubElement(groups, "group", display_name="Blocklist", ring="")

    root = ET.Element("root_contact")
    for contact in contacts:
        numbers = list(contact.numbers) + [""] * (3 - len(contact.numbers))
        ET.SubElement(
            root,
            "contact",
            display_name=contact.name,
            office_number=numbers[0],
            mobile_number=numbers[1],
            other_number=numbers[2],
            line="-1",
            ring="",
            group_id_name="All Contacts",
            default_photo="",
            auto_divert="",
        )

    declaration = b'<?xml version="1.0" encoding="UTF-8"?>\n'
    return (
        declaration
        + ET.tostring(groups, encoding="utf-8")
        + b"\n"
        + ET.tostring(root, encoding="utf-8")
        + b"\n"
    )


def refresh_phonebook():
    try:
        contacts = fetch_contacts()
        xml = render_phonebook(contacts)
        local_directory_xml = render_local_directory(contacts)
        with state.lock:
            state.xml = xml
            state.local_directory_xml = local_directory_xml
            state.contact_count = len(contacts)
            state.last_success = datetime.now(timezone.utc).isoformat()
            state.last_success_monotonic = time.monotonic()
            state.last_error = None
        logging.info("refreshed phonebook with %d contacts", len(contacts))
    except Exception as error:
        logging.exception("phonebook refresh failed")
        with state.lock:
            state.last_error = type(error).__name__


def refresh_loop():
    while True:
        refresh_phonebook()
        time.sleep(REFRESH_INTERVAL)


class RequestHandler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/livez":
            self.respond(b'{"status":"ok"}\n', "application/json", 200)
            return
        if path == "/healthz":
            with state.lock:
                age = (
                    time.monotonic() - state.last_success_monotonic
                    if state.last_success_monotonic is not None
                    else None
                )
                healthy = state.xml is not None and age <= REFRESH_INTERVAL * 2
                body = json.dumps(
                    {
                        "status": "ok" if healthy else "unavailable",
                        "contacts": state.contact_count,
                        "last_success": state.last_success,
                        "last_error": state.last_error,
                    }
                ).encode() + b"\n"
                status = 200 if healthy else 503
            self.respond(body, "application/json", status)
            return

        token = secret_value("phonebook-token", "PHONEBOOK_TOKEN")
        phonebook_path = f"/{token}/phonebook.xml"
        local_directory_path = f"/{token}/local-directory.xml"
        matched = True
        with state.lock:
            if hmac.compare_digest(path, phonebook_path):
                xml = state.xml
            elif hmac.compare_digest(path, local_directory_path):
                xml = state.local_directory_xml
            else:
                xml = None
                matched = False
        if not matched:
            self.respond(b"not found\n", "text/plain", 404)
            return
        if xml is None:
            self.respond(b"phonebook unavailable\n", "text/plain", 503)
            return
        self.respond(xml, "application/xml; charset=utf-8", 200, cache_control="private, max-age=300")

    def respond(self, body, content_type, status, cache_control="no-store"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", cache_control)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        logging.info("request from %s returned %s", self.client_address[0], args[1])


def main():
    if REFRESH_INTERVAL < 60:
        raise ValueError("REFRESH_INTERVAL must be at least 60 seconds")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    refresh_thread = threading.Thread(target=refresh_loop, daemon=True)
    refresh_thread.start()
    server = ThreadingHTTPServer(("", PORT), RequestHandler)
    logging.info("serving Yealink phonebook on port %d", PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
