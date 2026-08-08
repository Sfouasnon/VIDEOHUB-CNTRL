#!/usr/bin/env python3
"""Import port names, colors and groups from a Bitfocus Companion config.

A Companion routing page is a destination, and each key on it is a source. That
means the config already contains what an operator would otherwise retype into
Videohub CNTRL by hand: a human name for every port, the color they chose for
it, and — via the page name — a name for the destination too. This reads that
back out and writes it into the app's TileCustomizations.json.

Only labels and appearance are imported. Crosspoints are not: a Companion key
is a routing action, not a saved layout, and the app already learns live routes
from the router itself.

Deliberately a script rather than a feature in the app. A Companion export is
something you import once when you move a cart over, not something the app
needs to know how to parse forever.

Usage:
    ./script/import_companion_config.py CONFIG.companionconfig --router 172.20.114.84
    ./script/import_companion_config.py CONFIG.companionconfig --router ... --write
"""

from __future__ import annotations

import argparse
import collections
import gzip
import json
import pathlib
import re
import sys

# The accent names the app understands, in the order they are handed out to
# unrecognised Companion colors.
ACCENT_COLORS = [
    "blue", "cyan", "green", "yellow", "orange", "red", "purple", "pink",
    "teal", "indigo", "mint", "lime", "amber", "brown", "slate",
]

# Approximate RGB for each accent, used to map a Companion background color to
# the nearest thing the app can draw.
ACCENT_RGB = {
    "blue": (0x25, 0x63, 0xEB), "cyan": (0x08, 0x91, 0xB2),
    "green": (0x16, 0xA3, 0x4A), "yellow": (0xCA, 0x8A, 0x04),
    "orange": (0xEA, 0x58, 0x0C), "red": (0xDC, 0x26, 0x26),
    "purple": (0x7C, 0x3A, 0xED), "pink": (0xDB, 0x27, 0x77),
    "teal": (0x0D, 0x94, 0x88), "indigo": (0x4F, 0x46, 0xE5),
    "mint": (0x10, 0xB9, 0x81), "lime": (0x65, 0xA3, 0x0D),
    "amber": (0xD9, 0x77, 0x06), "brown": (0x78, 0x35, 0x0F),
    "slate": (0x47, 0x55, 0x69),
}

# Icon names the app understands, matched against the label text. Ordered:
# the first pattern that matches wins, so put specific terms before generic.
ICON_RULES = [
    (r"\bwitcam|\bcam\b|camera|\bcam\d", "camera"),
    (r"multi|\bmv\b|quad", "multiview"),
    (r"retarget", "retarget"),
    (r"mocap|motion.?cap", "motionCapture"),
    (r"simulcam|simul", "simulcam"),
    (r"engine|render|unreal|helios", "engine"),
    (r"scope|wfm|wave", "scopes"),
    (r"record|\brec\b|hyperdeck|\bhdk\b", "record"),
    (r"playback|\bpb\b|player", "playback"),
    (r"graphic|\bcg\b|title", "graphics"),
    (r"laptop|macbook|\bmac\b|\bpc\b", "laptop"),
    (r"convert|\bsdi\b|\bhdmi\b|updown|\bufc\b", "converter"),
    (r"return|\brtn\b|\bref\b", "return"),
    (r"router|videohub|\bvh\b", "router"),
    (r"monitor|\bmon\b|flanders|smallhd|display|\btv\b|desk|screen", "monitor"),
]

BUNDLE_ID = "com.videohubcntrl.VideohubCNTRL"
SUPPORT_FOLDER = "Videohub CNTRL"
STORE_FILENAME = "TileCustomizations.json"


def default_store() -> pathlib.Path:
    """Where the app actually keeps TileCustomizations.json.

    The app is sandboxed, so its "Application Support" is redirected into
    ~/Library/Containers/<bundle id>/Data. Writing to the plain
    ~/Library/Application Support path would succeed and then be invisible to
    the app, which is the most confusing possible outcome — so the container is
    preferred whenever it exists.
    """
    container = (
        pathlib.Path.home() / "Library" / "Containers" / BUNDLE_ID
        / "Data" / "Library" / "Application Support" / SUPPORT_FOLDER
    )
    if container.parent.parent.parent.exists():
        return container / STORE_FILENAME
    return pathlib.Path.home() / "Library" / "Application Support" / SUPPORT_FOLDER / STORE_FILENAME


def load_config(path: pathlib.Path) -> dict:
    """A .companionconfig is gzipped JSON; older exports are plain JSON."""
    raw = path.read_bytes()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return json.loads(raw)


def nearest_accent(rgb_int: int) -> str:
    r, g, b = (rgb_int >> 16) & 0xFF, (rgb_int >> 8) & 0xFF, rgb_int & 0xFF
    # Near-black is Companion's default background, not a deliberate choice, so
    # it must not drag every port onto the same dark accent.
    if r + g + b < 40:
        return None
    best, best_distance = None, None
    for name, (cr, cg, cb) in ACCENT_RGB.items():
        distance = (r - cr) ** 2 + (g - cg) ** 2 + (b - cb) ** 2
        if best_distance is None or distance < best_distance:
            best, best_distance = name, distance
    return best


def icon_for(label: str) -> str:
    lowered = label.lower()
    for pattern, icon in ICON_RULES:
        if re.search(pattern, lowered):
            return icon
    return "genericVideo"


def clean_label(text: str) -> str:
    """Companion labels carry markup and variables that mean nothing here."""
    text = re.sub(r"\$\([^)]*\)", "", text)        # $(instance:variable)
    text = re.sub(r"<[^>]+>", "", text)            # stray HTML
    text = text.replace("\\n", " ").replace("\n", " ")
    return re.sub(r"\s+", " ", text).strip()


def walk_controls(config: dict):
    """Yields (page_number, page_name, control) for every configured key."""
    for page_number, page in sorted(
        config.get("pages", {}).items(), key=lambda item: int(item[0])
    ):
        for row in page.get("controls", {}).values():
            for control in row.values():
                if isinstance(control, dict) and control.get("type", "").startswith("button"):
                    yield page_number, page.get("name", ""), control


def control_text(control: dict) -> str:
    for layer in control.get("style", {}).get("layers", []):
        if layer.get("type") == "text":
            value = (layer.get("text") or {}).get("value")
            if value:
                return clean_label(str(value))
    return ""


def control_background(control: dict) -> int | None:
    for layer in control.get("style", {}).get("layers", []):
        if layer.get("type") == "box":
            value = (layer.get("color") or {}).get("value")
            if isinstance(value, int):
                return value
    return None


def control_routes(control: dict):
    """Every (source, destination) pair this key can produce, across all steps."""
    for step in (control.get("steps") or {}).values():
        for action_set in (step.get("action_sets") or {}).values():
            for action in action_set:
                options = action.get("options") or {}
                source, destination = options.get("source"), options.get("destination")
                if isinstance(source, dict) and isinstance(destination, dict):
                    if isinstance(source.get("value"), int) and isinstance(destination.get("value"), int):
                        yield source["value"], destination["value"], action.get("connectionId")


def extract(config: dict, connection_id: str | None):
    """Collects candidate names and colors per port, with vote counts.

    A source appears on many pages with slightly different labels; taking the
    most common one is more reliable than taking the first.
    """
    source_names = collections.defaultdict(collections.Counter)
    source_colors = collections.defaultdict(collections.Counter)
    destination_names = collections.defaultdict(collections.Counter)
    connections_seen = collections.Counter()

    for _, page_name, control in walk_controls(config):
        label = control_text(control)
        background = control_background(control)
        routes = list(control_routes(control))

        for source, destination, route_connection in routes:
            connections_seen[route_connection] += 1
            if connection_id and route_connection != connection_id:
                continue
            if label:
                source_names[source][label] += 1
            if background is not None:
                accent = nearest_accent(background)
                if accent:
                    source_colors[source][accent] += 1
            page_label = clean_label(page_name)
            if page_label and page_label.upper() != "PAGE":
                destination_names[destination][page_label] += 1

    return source_names, source_colors, destination_names, connections_seen


def drop_shared_destination_names(destination_names, limit: int = 2):
    """Discards page names that describe a signal type rather than a place.

    Most Companion pages are one destination — "BrainBar Mon", "VV Left" — and
    the page name is exactly what that output should be called. But some pages
    are organised by signal instead ("EXT LUT", "INT LUT") and route to many
    different outputs. Naming eight destinations "EXT LUT" is worse than
    leaving them with their router labels, so those names are dropped.
    """
    winners = {
        index: names.most_common(1)[0][0]
        for index, names in destination_names.items()
        if names
    }
    usage = collections.Counter(winners.values())
    return {
        index: names
        for index, names in destination_names.items()
        if names and usage[winners[index]] <= limit
    }


def build_entries(router: str, source_names, source_colors, destination_names) -> list[dict]:
    entries = []

    for index, names in sorted(source_names.items()):
        name = names.most_common(1)[0][0]
        colors = source_colors.get(index)
        entries.append({
            "key": {"routerIdentity": router, "kind": "source", "protocolPortIndex": index},
            "customization": {
                "displayNameOverride": name,
                "accentColor": colors.most_common(1)[0][0] if colors else "blue",
                "icon": icon_for(name),
            },
        })

    for index, names in sorted(destination_names.items()):
        name = names.most_common(1)[0][0]
        entries.append({
            "key": {"routerIdentity": router, "kind": "destination", "protocolPortIndex": index},
            "customization": {
                "displayNameOverride": name,
                "accentColor": "slate",
                "icon": icon_for(name),
            },
        })

    return entries


def merge(store_path: pathlib.Path, entries: list[dict], router: str) -> dict:
    """Replaces this router's entries, leaving other routers' untouched.

    Customizations are stored per router, so importing a cart's Companion
    config must not disturb the tiles you already tuned on a different one.
    """
    existing = []
    if store_path.exists():
        try:
            existing = json.loads(store_path.read_text()).get("entries", [])
        except (json.JSONDecodeError, OSError) as error:
            print(f"warning: could not read {store_path}: {error}", file=sys.stderr)

    kept = [
        entry for entry in existing
        if entry.get("key", {}).get("routerIdentity") != router
    ]

    combined = kept + entries
    combined.sort(key=lambda entry: (
        entry["key"]["routerIdentity"],
        entry["key"]["kind"],
        entry["key"]["protocolPortIndex"],
    ))
    return {"schemaVersion": 1, "entries": combined}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("config", type=pathlib.Path, help=".companionconfig export")
    parser.add_argument(
        "--router", required=True,
        help="Router identity: the host or IP exactly as entered in the app, lowercased",
    )
    parser.add_argument(
        "--connection",
        help="Only import keys targeting this Companion connection id or label. "
             "Use --list-connections to see them.",
    )
    parser.add_argument("--list-connections", action="store_true", help="List Videohub connections and exit")
    parser.add_argument(
        "--store", type=pathlib.Path, default=None,
        help="TileCustomizations.json to update (defaults to the app's sandbox container)",
    )
    parser.add_argument("--write", action="store_true", help="Actually write; otherwise prints a preview")
    args = parser.parse_args()

    if args.store is None:
        args.store = default_store()

    config = load_config(args.config)

    instances = {
        key: value.get("label", key)
        for key, value in config.get("instances", {}).items()
        if isinstance(value, dict)
    }

    if args.list_connections:
        _, _, _, seen = extract(config, None)
        for connection_id, count in seen.most_common():
            print(f"{instances.get(connection_id, '(unknown)'):24} {connection_id or '(none)':24} {count} route keys")
        return 0

    connection_id = args.connection
    if connection_id and connection_id not in instances:
        matches = [key for key, label in instances.items() if label == connection_id]
        if not matches:
            print(f"error: no connection named or id'd {connection_id!r}", file=sys.stderr)
            return 2
        connection_id = matches[0]

    router = args.router.strip().lower()
    source_names, source_colors, destination_names, _ = extract(config, connection_id)
    destination_names = drop_shared_destination_names(destination_names)
    entries = build_entries(router, source_names, source_colors, destination_names)

    print(f"Router identity : {router}")
    print(f"Sources         : {len(source_names)}")
    print(f"Destinations    : {len(destination_names)}")
    print()
    for entry in entries[:60]:
        key, customization = entry["key"], entry["customization"]
        print(f"  {key['kind']:11} {key['protocolPortIndex'] + 1:>3}  "
              f"{customization['displayNameOverride']:<26} "
              f"{customization['accentColor']:<8} {customization['icon']}")
    if len(entries) > 60:
        print(f"  … and {len(entries) - 60} more")

    if not args.write:
        print(f"\nPreview only. Re-run with --write to update {args.store}")
        return 0

    document = merge(args.store, entries, router)
    args.store.parent.mkdir(parents=True, exist_ok=True)
    args.store.write_text(json.dumps(document, indent=2, sort_keys=True))
    print(f"\nWrote {len(entries)} entries for {router} to {args.store}")
    print("Restart Videohub CNTRL to pick them up.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
