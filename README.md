# Videohub On-Set

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

## Layout

```
VideohubOnSet/
  App/        SwiftUI app entry point and AppDelegate
  Models/     PortNumber, Route, Salvo, VideoInput/Output, TileStyle, …
  Services/   VideohubClient (TCP), VideohubProtocolParser, VideohubDiscovery
  Stores/     RouterStore, SalvoStore, CustomizationStore (@Observable)
  Views/      RouterGridView, SourceTile, DestinationTile, ActionPanel, …
  Support/    Icons, port presentation, menu commands
VideohubOnSetTests/   Unit tests, incl. a live-hardware integration suite
TestSupport/          mock_videohub_server.py — development-only TCP stub
script/               build_and_run.sh
Resources/            AppIcon.iconset (used by the SwiftPM bundle path)
```

## Building and running

```bash
./script/build_and_run.sh            # build and launch
./script/build_and_run.sh --debug    # launch under lldb
./script/build_and_run.sh --logs     # launch and stream process logs
./script/build_and_run.sh --verify   # launch and confirm it stays running
```

The script prefers `xcodebuild` with `VideohubOnSet.xcodeproj`. If full Xcode
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

## Network access

The app connects to routers on the local network and requires the local network
permission (`NSLocalNetworkUsageDescription`) on macOS.

## License

MIT — see [LICENSE](LICENSE).
