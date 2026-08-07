# Videohub On-Set — Stream Deck plugin

Routes a Blackmagic Videohub from a Stream Deck, replacing a Companion install
for routing work.

## How it fits together

```
Videohub ──TCP 9990──▶ Videohub On-Set.app ──TCP 9992 (loopback)──▶ Stream Deck plugin
```

The plugin never opens its own connection to the router. The app already owns
that session, along with the port names, colors, icons and salvos the operator
configured — so a key inherits all of it instead of being set up twice, and the
router only ever has one writer.

The consequence worth knowing: **the app must be running.** When it isn't, keys
dim and show a slash rather than firing blind.

## Setup

1. In Videohub On-Set: **Settings → Stream Deck & Surface Control → Enable
   surface control**. Note the port (default `9992`).
2. Build and install the plugin:

   ```bash
   cd streamdeck
   npm install
   npm run watch     # or: npm run build
   ```

   `npm run watch` installs it into Stream Deck and reloads on every change.
   Requires the [Stream Deck CLI](https://docs.elgato.com/streamdeck/cli/intro)
   (`npm install -g @elgato/cli`) and Stream Deck 6.6+.
3. The plugin's actions appear under **Videohub On-Set** in the actions list.

## Actions

### Route

One key, a list of steps. Each press runs the current step and advances to the
next, wrapping around — the same model as a Companion multi-step button.

- **One step, one crosspoint** — a plain routing key. Press to take.
- **One step, several crosspoints** — one press moves several destinations at
  once. Applied as a unit: if the app refuses any of them (locked destination,
  offline router), none are sent.
- **Several steps** — an A/B/C key. The badge in the corner shows `2/4`.

The key lights up when the route is live on the router, and keeps up with
changes made anywhere else — the app's own window, Blackmagic's software, a
front panel. Feedback is evaluated across *every* step, so an A/B key lights for
whichever variant is currently on air.

Labels and colors come from the ports as configured in the app; the per-step
**Label** field overrides that.

### Salvo

Fires a salvo stored in the app. The key holds only the salvo's identifier, not
a copy of its crosspoints, so editing the salvo in the app updates every key
bound to it. Lights when all of the salvo's crosspoints are live.

Salvos are stored per router, so a key bound on one Videohub shows
"Not on this router" when the app is connected to a different one.

## Migrating from Companion

Companion's model maps over directly:

| Companion | Here |
| --- | --- |
| A page pinned to one destination | A Stream Deck profile of Route keys sharing a destination |
| Button with one `route` action | Route key, one step, one crosspoint |
| Button with several `route` actions | Route key, one step, several crosspoints |
| Multi-step button | Route key with several steps |
| `input_bg` feedback | Automatic — no configuration |
| Port labels and button colors | Imported once, see below |

Port names and colors carry over with:

```bash
./script/import_companion_config.py my-config.companionconfig \
    --router 172.20.114.84 --connection SmartcartRouter --write
```

Key layout is not imported — assign actions to keys in Stream Deck.

## Protocol

Newline-delimited JSON over loopback TCP. `src/protocol.ts` and the app's
`VideohubOnSet/Services/ControlProtocol.swift` are two halves of one contract
and must change together; `PROTOCOL_VERSION` makes a mismatch fail loudly at
connect rather than quietly at the crosspoint.

## Development

```bash
npm run typecheck   # tsc --noEmit
npm run build       # rollup, writes the .sdPlugin/bin
streamdeck dev      # enables the property inspector debugger on :23654
```

Plugin logs land in `com.videohubonset.control.sdPlugin/logs/`.
