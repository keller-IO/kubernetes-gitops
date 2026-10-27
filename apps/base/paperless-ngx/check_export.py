"""Prueft einen document_exporter-Export, bevor rclone ihn offsite spiegelt.

Ein Export ohne Dokumente (falsche oder leere Datenbank) oder mit fehlenden
Originalen darf export/current in Garage nicht ersetzen. Scheitert die
Pruefung, endet der Init-Container mit Fehler und der rclone-Container startet
nicht; der Gatus-Heartbeat schlaegt an.

Nutzung: python3 check_export.py EXPORTVERZEICHNIS
"""

import json
import sys
from pathlib import Path

# documents/settings.py: EXPORTER_FILE_NAME
EXPORTED_FILE_NAME = "__exported_file_name__"


def check(export_dir):
    """Liefert (Anzahl Dokumente, fehlende Originale) laut manifest.json."""
    export_dir = Path(export_dir)
    manifest = json.loads((export_dir / "manifest.json").read_text(encoding="utf-8"))
    docs = [o for o in manifest if o.get("model") == "documents.document"]
    missing = [
        o.get(EXPORTED_FILE_NAME) or f"pk {o.get('pk')}"
        for o in docs
        if not o.get(EXPORTED_FILE_NAME) or not (export_dir / o[EXPORTED_FILE_NAME]).is_file()
    ]
    return len(docs), missing


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    try:
        count, missing = check(argv[1])
    except (OSError, ValueError, TypeError, AttributeError) as e:
        print(f"manifest.json unlesbar: {e}", file=sys.stderr)
        return 1
    print(f"manifest.json: {count} Dokumente, {len(missing)} Originale fehlen")
    for name in missing[:20]:
        print(f"  fehlt: {name}", file=sys.stderr)
    if count == 0:
        print("Export ohne Dokumente, Offsite-Abbild bleibt unveraendert", file=sys.stderr)
        return 1
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
