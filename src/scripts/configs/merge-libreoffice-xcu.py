#!/usr/bin/env python3
"""Merge managed entries into LibreOffice's registrymodifications.xcu.

Each entry is a "path|name|value" triple:
  path  — XCU item oor:path attribute (e.g. /org.openoffice.UserProfile/Data)
  name  — XCU prop oor:name attribute (e.g. sn)
  value — XCU value text content (e.g. "")

For each entry:
  - If the item exists and the prop exists: update <value>.
  - If the item exists but the prop doesn't: insert <prop> before </item>.
  - If the item doesn't exist: insert <item> before </oor:items>.
  - If the file doesn't exist: create it with the managed entries.
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NS = {
    "oor": "http://openoffice.org/2001/registry",
    "xlink": "http://www.w3.org/1999/xlink",
}

# Register namespace prefixes so ElementTree writes "oor:" and "xlink:"
# instead of auto-generated "ns0:" and "ns1:" prefixes.
ET.register_namespace("oor", NS["oor"])
ET.register_namespace("xlink", NS["xlink"])

XCU_HEADER = """\
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE oor:items PUBLIC "-//OpenOffice.org//DTD OfficeDocument 1.0//EN" "items.dtd">
<oor:items xmlns:oor="http://openoffice.org/2001/registry"
           xmlns:xlink="http://www.w3.org/1999/xlink">
</oor:items>"""


def _find_prop_in_items(items_elem, item_path, prop_name):
    """Find a <prop> by oor:name within any <item> matching oor:path.

    LibreOffice stores one prop per <item>, so multiple <item> elements share
    the same oor:path.  We must search across all of them.
    """
    for item in items_elem.findall("item"):
        if item.get(f"{{{NS['oor']}}}path") == item_path:
            for prop in item.findall("prop"):
                if prop.get(f"{{{NS['oor']}}}name") == prop_name:
                    return prop
    return None


def _set_value(prop_elem, value):
    """Set or replace the <value> text within a <prop>."""
    value_elem = prop_elem.find("value")
    if value_elem is not None:
        value_elem.text = value
    else:
        value_elem = ET.SubElement(prop_elem, "value")
        value_elem.text = value


def _ensure_item(items_elem, item_path):
    """Return an existing <item> for item_path, or create a new one."""
    for item in items_elem.findall("item"):
        if item.get(f"{{{NS['oor']}}}path") == item_path:
            return item
    item = ET.SubElement(items_elem, "item")
    item.set(f"{{{NS['oor']}}}path", item_path)
    return item


def merge_entries(xcu_path, entries):
    """Merge entries into the XCU file at xcu_path.

    entries: list of (path, name, value) tuples.
    """
    xcu_file = Path(xcu_path)

    if xcu_file.exists():
        tree = ET.parse(xcu_file)
        root = tree.getroot()
        items_elem = (
            root if root.tag == f"{{{NS['oor']}}}items" else root.find("oor:items", NS)
        )
        if items_elem is None:
            items_elem = ET.SubElement(root, f"{{{NS['oor']}}}items")
    else:
        xcu_file.parent.mkdir(parents=True, exist_ok=True)
        root = ET.fromstring(XCU_HEADER)
        items_elem = root
        tree = ET.ElementTree(root)

    for item_path, prop_name, value in entries:
        prop = _find_prop_in_items(items_elem, item_path, prop_name)
        if prop is not None:
            _set_value(prop, value)
        else:
            item = _ensure_item(items_elem, item_path)
            prop = ET.SubElement(item, "prop")
            prop.set(f"{{{NS['oor']}}}name", prop_name)
            _set_value(prop, value)

    tree.write(xcu_file, xml_declaration=True, encoding="UTF-8")


def main():
    if len(sys.argv) < 2:
        print(
            "Usage: merge-libreoffice-xcu.py <xcu-file> [path|name|value ...]",
            file=sys.stderr,
        )
        sys.exit(1)

    xcu_path = sys.argv[1]
    entries = []
    for arg in sys.argv[2:]:
        parts = arg.split("|", 2)
        if len(parts) != 3:
            print(
                f"Invalid entry format: {arg} (expected path|name|value)",
                file=sys.stderr,
            )
            sys.exit(1)
        entries.append(tuple(parts))

    if entries:
        merge_entries(xcu_path, entries)


if __name__ == "__main__":
    main()
