# Videohub CNTRL

A native macOS control surface for Blackmagic Design Videohub routers, built for
on-set use: large touch-friendly tiles, an explicit source → destination → TAKE
workflow, and no dependency on Blackmagic's own control app.

Written in Swift 5 / SwiftUI, targeting macOS 14+.

## Features

- **Bonjour discovery** — browses `_videohub._tcp` and `_blackmagic._tcp`,
  collapses duplicate advertisements from a single chassis, and probes the
  control port (9990) so a router only appears once it actually answers with a
  `VIDEOHUB DEVICE` block.
- **Live routing** — one long-lived TCP connection to the router with
  exponential reconnect backoff. Route changes made elsewhere on the network
  show up immediately.
- **Source → destination → TAKE** — nothing is switched until you confirm, with
  a route preview showing exactly what is about to change.
- **Salvos (macros)** — named groups of crosspoints taken together. Stored per
  router identity, so one Videohub's macros never leak into another's.
- **Tile customization** — per-port display names, accent colors, icons, and
  groups. Styles can be copied between tiles; names deliberately cannot, since a
  name belongs to one physical port.
- **Signal format badges** and destination lock state surfaced on the tiles.
- **Stream Deck control** — an optional loopback control API lets the bundled
  Stream Deck plugin drive the router using the same names, colors and salvos,
  replacing Bitfocus Companion for routing. See
  [`streamdeck/README.md`](streamdeck/README.md).

## Layout

```
VideohubCNTRL/
  App/        SwiftUI app entry point and AppDelegate
  Models/     PortNumber, Route, Salvo, VideoInput/Output, TileStyle, …
  Services/   VideohubClient (TCP), VideohubProtocolParser, VideohubDiscovery
  Stores/     RouterStore, SalvoStore, CustomizationStore (@Observable)
  Views/      RouterGridView, SourceTile, DestinationTile, ActionPanel, …
  Support/    Icons, port presentation, menu commands
VideohubCNTRLTests/   Unit tests, incl. a live-hardware integration suite
TestSupport/          mock_videohub_server.py — development-only TCP stub
script/               build_and_run.sh, import_companion_config.py
streamdeck/           Stream Deck plugin (TypeScript)
Resources/            AppIcon.iconset (used by the SwiftPM bundle path)
```

## Building and running

```bash
./script/build_and_run.sh            # build and launch
./script/build_and_run.sh --debug    # launch under lldb
./script/build_and_run.sh --logs     # launch and stream process logs
./script/build_and_run.sh --verify   # launch and confirm it stays running
```

The script prefers `xcodebuild` with `VideohubCNTRL.xcodeproj`. If full Xcode
isn't selected, it falls back to SwiftPM and hand-stages a `.app` bundle in
`dist/` — compiling the iconset with `iconutil`, writing an `Info.plist`, and
ad-hoc codesigning with the app's entitlements.

Building directly also works:

```bash
swift build
swift test
```

## Testing without hardware

`TestSupport/mock_videohub_server.py` is a small Smart Videohub TCP stub. It
intentionally fragments its initial status dump across awkward packet sizes and
pushes an unsolicited route update, which is the behavior the parser tests care
about. It is not a full protocol simulator.

Debug builds also accept development flags:

```bash
--demo                  # 40 synthetic ports, no router needed
--demo-size N           # synthetic router with N ports
--port N                # connect to a non-default control port
--window-size W H       # fixed window size
--qa-session NAME       # isolated UserDefaults + customization store
```

## Upgrading from "Videohub On-Set"

The app was renamed from Videohub On-Set to Videohub CNTRL. That changed the
bundle identifier, which moves the macOS sandbox container — and a sandboxed app
cannot read another app's container, so the app can't migrate itself.

Tile names and salvos are carried across automatically *within* a container. To
bring settings over from the old build:

```bash
./script/build_and_run.sh                      # launch once so the new container exists
./script/migrate_from_videohub_onset.sh        # preview
./script/migrate_from_videohub_onset.sh --write
```

It copies rather than moves, and refuses to overwrite anything already saved
under the new name, so it is safe to run twice. The old container is left intact
at `~/Library/Containers/com.videohubonset.VideohubOnSet` — delete it once you're
satisfied nothing is missing.

## Network access

The app connects to routers on the local network and requires the local network
permission (`NSLocalNetworkUsageDescription`) on macOS.

## License

MIT — see [LICENSE](LICENSE).
