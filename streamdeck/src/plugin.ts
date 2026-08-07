import streamDeck from "@elgato/streamdeck";

import { RouteAction } from "./actions/route";
import { SalvoAction } from "./actions/salvo";
import { bridge } from "./bridge";
import { DEFAULT_PORT } from "./protocol";

type GlobalSettings = {
	port?: number;
};

streamDeck.actions.registerAction(new RouteAction());
streamDeck.actions.registerAction(new SalvoAction());

// The port is global rather than per-key: every key talks to the same app, so
// making it per-key would only create the opportunity for keys to disagree.
streamDeck.settings.onDidReceiveGlobalSettings<GlobalSettings>((ev) => {
	bridge.setPort(ev.settings.port ?? DEFAULT_PORT);
});

await streamDeck.connect();
await streamDeck.settings.getGlobalSettings<GlobalSettings>();

bridge.connect();
