import type { JsonObject } from "@elgato/utils";
import streamDeck, {
	action,
	SingletonAction,
	type DidReceiveSettingsEvent,
	type KeyAction,
	type KeyDownEvent,
	type SendToPluginEvent,
	type WillAppearEvent
} from "@elgato/streamdeck";

import { bridge } from "../bridge";
import { isLive } from "../protocol";
import { renderKey } from "../render";

export type SalvoSettings = {
	/** UUID of a salvo stored in the app, scoped to the connected router. */
	salvoID?: string;
	title?: string;
} & JsonObject;

/**
 * Fires a salvo that lives in the app.
 *
 * The crosspoints are deliberately not copied into the key's settings. Salvos
 * get edited — a monitor moves, a feed is renamed — and a key holding its own
 * copy would keep firing the old layout long after the app was corrected.
 * Holding only the identifier means editing the salvo in the app updates every
 * key bound to it.
 */
@action({ UUID: "com.videohubcntrl.control.salvo" })
export class SalvoAction extends SingletonAction<SalvoSettings> {
	constructor() {
		super();
		bridge.onSnapshot(() => void this.refreshAll());
	}

	override async onWillAppear(ev: WillAppearEvent<SalvoSettings>): Promise<void> {
		if (ev.action.isKey()) {
			await this.draw(ev.action, ev.payload.settings);
		}
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<SalvoSettings>): Promise<void> {
		if (ev.action.isKey()) {
			await this.draw(ev.action, ev.payload.settings);
		}
	}

	override async onSendToPlugin(ev: SendToPluginEvent<JsonObject, SalvoSettings>): Promise<void> {
		const payload = ev.payload as { request?: string };
		if (payload?.request !== "snapshot") {
			return;
		}
		await bridge.refresh();
		await streamDeck.ui.sendToPropertyInspector({
			event: "snapshot",
			connected: bridge.connected,
			snapshot: bridge.snapshot ?? null
		} as unknown as JsonObject);
	}

	override async onKeyDown(ev: KeyDownEvent<SalvoSettings>): Promise<void> {
		const salvoID = ev.payload.settings?.salvoID;
		if (!salvoID) {
			await ev.action.showAlert();
			streamDeck.logger.warn("Salvo key pressed with no salvo selected");
			return;
		}
		const error = await bridge.fireSalvo(salvoID);
		if (error) {
			await ev.action.showAlert();
			streamDeck.logger.warn(`Salvo refused: ${error}`);
		}
	}

	private async refreshAll(): Promise<void> {
		for (const visible of this.actions) {
			if (!visible.isKey()) {
				continue;
			}
			await this.draw(visible, await visible.getSettings());
		}
	}

	private async draw(target: KeyAction<SalvoSettings>, settings: SalvoSettings | undefined): Promise<void> {
		const snapshot = bridge.snapshot;
		const salvoID = settings?.salvoID;

		if (!salvoID) {
			await target.setImage(renderKey({ primary: "No salvo", live: false, unavailable: true }));
			return;
		}

		const salvo = snapshot?.salvos.find((candidate) => candidate.id === salvoID);
		if (!salvo) {
			// Either the app is closed, or this key was bound on a different
			// router. Both read the same on the key, and both mean "do not
			// trust this key right now".
			await target.setImage(
				renderKey({
					primary: settings?.title ?? "Salvo",
					secondary: snapshot === null ? undefined : "Not on this router",
					live: false,
					unavailable: true
				})
			);
			return;
		}

		await target.setImage(
			renderKey({
				primary: settings?.title && settings.title.length > 0 ? settings.title : salvo.name,
				secondary: `${salvo.crosspoints.length} crosspoints`,
				color: salvo.color,
				live: snapshot !== null && isLive(salvo.crosspoints, snapshot.routes),
				unavailable: snapshot === null
			})
		);
	}
}
