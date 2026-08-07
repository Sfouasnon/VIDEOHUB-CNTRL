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
import { isLive, type Crosspoint, type Snapshot } from "../protocol";
import { renderKey } from "../render";

/**
 * One press of the key. A step carries a list of crosspoints rather than a
 * single one so a key can drive several destinations at once — a "go to
 * playback" key that moves four monitors is one step, not four keys.
 */
export type RouteStep = {
	crosspoints: Crosspoint[];
	/** Overrides the label derived from port names. */
	title?: string;
	/** Overrides the color inherited from the source port. */
	color?: string;
};

export type RouteSettings = {
	steps?: RouteStep[];
	/** Show the destination on the top line. Off for a page pinned to one
	 *  destination, where repeating it on every key is noise. */
	showDestination?: boolean;
	/** Persisted so a stepped key resumes where it left off after the deck
	 *  changes page, matching Companion. */
	stepIndex?: number;
} & JsonObject;

function normalizeSteps(settings: RouteSettings | undefined): RouteStep[] {
	const steps = settings?.steps;
	if (!Array.isArray(steps)) {
		return [];
	}
	return steps
		.map((step) => ({
			title: typeof step?.title === "string" ? step.title : undefined,
			color: typeof step?.color === "string" ? step.color : undefined,
			// Settings come from a hand-editable JSON blob, so every field is
			// validated rather than trusted. A malformed crosspoint here would
			// otherwise reach the router as a route to port NaN.
			crosspoints: Array.isArray(step?.crosspoints)
				? (step.crosspoints as unknown[]).filter((candidate): candidate is Crosspoint => {
						const crosspoint = candidate as Partial<Crosspoint> | null;
						return (
							Number.isInteger(crosspoint?.output) &&
							Number.isInteger(crosspoint?.input) &&
							(crosspoint?.output ?? -1) >= 0 &&
							(crosspoint?.input ?? -1) >= 0
						);
					})
				: []
		}))
		.filter((step) => step.crosspoints.length > 0);
}

function portName(snapshot: Snapshot | null, kind: "inputs" | "outputs", index: number): string {
	const port = snapshot?.[kind].find((candidate) => candidate.index === index);
	return port?.name ?? `${kind === "inputs" ? "In" : "Out"} ${index + 1}`;
}

function portColor(snapshot: Snapshot | null, index: number): string | undefined {
	return snapshot?.inputs.find((candidate) => candidate.index === index)?.color;
}

/**
 * A routing key: press to take, with optional steps that cycle on repeat
 * presses.
 *
 * The step model is Companion's, because that is what the operators already
 * know: the key runs the current step's actions, then advances. Feedback is
 * evaluated across *all* steps rather than only the current one, so an A/B key
 * lights up whichever variant is live — which is what the operator actually
 * needs to see.
 */
@action({ UUID: "com.videohubonset.control.route" })
export class RouteAction extends SingletonAction<RouteSettings> {
	constructor() {
		super();
		bridge.onSnapshot(() => void this.refreshAll());
	}

	override async onWillAppear(ev: WillAppearEvent<RouteSettings>): Promise<void> {
		if (ev.action.isKey()) {
			await this.draw(ev.action, ev.payload.settings);
		}
	}

	override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<RouteSettings>): Promise<void> {
		if (ev.action.isKey()) {
			await this.draw(ev.action, ev.payload.settings);
		}
	}

	/** Feeds the property inspector live port lists so its dropdowns show real
	 *  names instead of asking the operator to remember port numbers. */
	override async onSendToPlugin(ev: SendToPluginEvent<JsonObject, RouteSettings>): Promise<void> {
		const payload = ev.payload as { request?: string };
		if (payload?.request !== "snapshot") {
			return;
		}
		await bridge.refresh();
		// Addressed to the visible property inspector rather than to the
		// action, because only one inspector is ever open.
		await streamDeck.ui.sendToPropertyInspector({
			event: "snapshot",
			connected: bridge.connected,
			snapshot: bridge.snapshot ?? null
		} as unknown as JsonObject);
	}

	override async onKeyDown(ev: KeyDownEvent<RouteSettings>): Promise<void> {
		const settings = ev.payload.settings;
		const steps = normalizeSteps(settings);
		if (steps.length === 0) {
			await ev.action.showAlert();
			streamDeck.logger.warn("Route key pressed with no crosspoints configured");
			return;
		}

		const index = this.currentIndex(settings, steps.length);
		const step = steps[index]!;
		const error = await bridge.route(step.crosspoints);

		if (error) {
			// The app refused — locked destination, offline router, port
			// outside the topology. Do not advance, or a second press would
			// silently skip a step the operator never got to fire.
			await ev.action.showAlert();
			streamDeck.logger.warn(`Route refused: ${error}`);
			return;
		}

		if (steps.length > 1) {
			await ev.action.setSettings({ ...settings, stepIndex: (index + 1) % steps.length });
		}
	}

	private currentIndex(settings: RouteSettings | undefined, count: number): number {
		const stored = settings?.stepIndex;
		if (!Number.isInteger(stored) || stored === undefined || stored < 0) {
			return 0;
		}
		// Modulo rather than clamp, so removing steps in the property
		// inspector cannot strand the key on an index that no longer exists.
		return stored % count;
	}

	private async refreshAll(): Promise<void> {
		for (const visible of this.actions) {
			if (!visible.isKey()) {
				continue;
			}
			const settings = await visible.getSettings();
			await this.draw(visible, settings);
		}
	}

	private async draw(target: KeyAction<RouteSettings>, settings: RouteSettings | undefined): Promise<void> {
		const snapshot = bridge.snapshot;
		const steps = normalizeSteps(settings);

		if (steps.length === 0) {
			await target.setImage(renderKey({ primary: "Not set", live: false, unavailable: true }));
			return;
		}

		const index = this.currentIndex(settings, steps.length);
		const step = steps[index]!;
		const first = step.crosspoints[0]!;

		// Live is evaluated across every step, so an A/B key lights for
		// whichever variant is currently on the router.
		const live = snapshot !== null && steps.some((candidate) => isLive(candidate.crosspoints, snapshot.routes));

		const primary =
			step.title && step.title.length > 0
				? step.title
				: step.crosspoints.length > 1
					? `${portName(snapshot, "inputs", first.input)} +${step.crosspoints.length - 1}`
					: portName(snapshot, "inputs", first.input);

		const secondary =
			settings?.showDestination && step.crosspoints.length === 1
				? portName(snapshot, "outputs", first.output)
				: settings?.showDestination
					? `${step.crosspoints.length} destinations`
					: undefined;

		await target.setImage(
			renderKey({
				primary,
				secondary,
				color: step.color ?? portColor(snapshot, first.input),
				live,
				badge: steps.length > 1 ? `${index + 1}/${steps.length}` : undefined,
				unavailable: snapshot === null
			})
		);
	}
}
