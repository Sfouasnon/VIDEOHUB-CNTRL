#!/usr/bin/env python3
"""Regenerates the Companion export fixture used by the import tests.

CompanionConfigImportTests.swift embeds this file base64-encoded, and every
expectation in it was captured by running script/import_companion_config.py
against this exact export. That is what keeps the Swift importer and the script
honest about each other.

If a rule changes, regenerate and re-capture together:

    ./TestSupport/make_companion_fixture.py
    ./script/import_companion_config.py /tmp/fixture.companionconfig \
        --router 169.254.171.201 --connection vh1

then paste the new base64 (printed below) and the new expected rows into the
test. Do not hand-edit the base64.
"""

import base64
import gzip
import json
import pathlib
import textwrap

OUTPUT = pathlib.Path("/tmp/fixture.companionconfig")


def button(text, color, routes, connection="vh1"):
    """One Companion key. `routes` is a list of (source, destination) pairs."""
    actions = [
        {
            "connectionId": connection,
            "options": {"source": {"value": source}, "destination": {"value": destination}},
        }
        for source, destination in routes
    ]
    layers = [{"type": "text", "text": {"value": text}}]
    if color is not None:
        layers.append({"type": "box", "color": {"value": color}})
    return {
        "type": "button",
        "style": {"layers": layers},
        "steps": {"0": {"action_sets": {"down": actions}}},
    }


def build_config():
    pages = {}

    # One page per destination, which is the normal Companion layout.
    pages["1"] = {
        "name": "BrainBar Mon",
        "controls": {
            "0": {
                "0": button("Cam A", 0x2563EB, [(0, 0)]),
                "1": button("HyperDeck 1", 0xDC2626, [(1, 0)]),
                "2": button("Unreal Engine", 0x16A34A, [(2, 0)]),
                # Near-black is Companion's default, not a colour choice.
                "3": button("Flanders", 0x000000, [(3, 0)]),
            }
        },
    }

    # Source 0 is labelled twice here, so the majority label must win.
    pages["2"] = {
        "name": "VV Left",
        "controls": {
            "0": {
                "0": button("Cam A", 0x2563EB, [(0, 1)]),
                "1": button("Wrong Name", 0x2563EB, [(0, 1)]),
                "2": button("Multiview 1", 0xCA8A04, [(4, 1)]),
            }
        },
    }

    # Four pages sharing a name that describes a signal, not a place. Above the
    # limit of 2, so none of these destinations should be renamed.
    for page, destination in enumerate([2, 3, 4, 5], start=3):
        pages[str(page)] = {
            "name": "EXT LUT",
            "controls": {"0": {"0": button("SDI Converter", 0x0891B2, [(5, destination)])}},
        }

    # A second Videohub connection, to prove filtering works.
    pages["7"] = {
        "name": "Other Router",
        "controls": {"0": {"0": button("Foreign Cam", 0xDB2777, [(9, 9)], connection="vh2")}},
    }

    # Markup and variables that carry no meaning once imported.
    pages["8"] = {
        "name": "Village <b>Mon</b>",
        "controls": {"0": {"0": button("Return $(internal:page)  A\\nB", 0x7C3AED, [(6, 6)])}},
    }

    return {
        "version": 4,
        "instances": {"vh1": {"label": "Smart Videohub"}, "vh2": {"label": "Backup Hub"}},
        "pages": pages,
    }


def main():
    raw = json.dumps(build_config()).encode()

    # mtime is pinned so the gzip bytes, and therefore the base64 in the test,
    # are reproducible rather than changing on every run.
    with open(OUTPUT, "wb") as handle:
        with gzip.GzipFile(
            filename="fixture.companionconfig", mode="wb", fileobj=handle, mtime=1_735_689_600
        ) as archive:
            archive.write(raw)

    encoded = base64.b64encode(OUTPUT.read_bytes()).decode()
    print(f"// plain JSON is {len(raw)} bytes")
    for index, line in enumerate(textwrap.wrap(encoded, 76)):
        prefix = "        " if index == 0 else "        + "
        print(f'{prefix}"{line}"')
    print(f"\nWrote {OUTPUT}")


if __name__ == "__main__":
    main()
