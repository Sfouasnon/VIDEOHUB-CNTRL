/**
 * Mirror of the app's `ControlProtocol.swift`. Both files must move together;
 * `PROTOCOL_VERSION` is what makes a mismatch loud instead of silent.
 */
export const PROTOCOL_VERSION = 1;
export const DEFAULT_PORT = 9992;

export type Crosspoint = {
	/** Destination, zero-based, same numbering as Companion's `destination`. */
	output: number;
	/** Source, zero-based, same numbering as Companion's `source`. */
	input: number;
};

export type PortInfo = {
	index: number;
	number: number;
	routerLabel: string;
	name: string;
	color: string;
	icon: string;
	group?: string | null;
	format?: string | null;
	routedInput?: number | null;
	lock?: string | null;
};

export type SalvoInfo = {
	id: string;
	name: string;
	color: string;
	icon: string;
	crosspoints: Crosspoint[];
};

export type RouterInfo = {
	identity: string;
	name: string;
	inputCount: number;
	outputCount: number;
	isReady: boolean;
};

export type Snapshot = {
	connection: "offline" | "connecting" | "connected";
	router: RouterInfo;
	inputs: PortInfo[];
	outputs: PortInfo[];
	/** Keyed by output index as a string, valued by input index. */
	routes: Record<string, number>;
	salvos: SalvoInfo[];
};

export type ServerEvent =
	| { type: "hello"; protocolVersion: number; app: string; appVersion: string }
	| { type: "snapshot"; snapshot: Snapshot }
	| { type: "ack"; id: string; ok: boolean; error?: string }
	| { type: "notice"; kind: string; message: string };

/** Accent colors the app offers, resolved to the hex the deck should draw. */
export const ACCENT_COLORS: Record<string, string> = {
	blue: "#2563eb",
	cyan: "#0891b2",
	green: "#16a34a",
	yellow: "#ca8a04",
	orange: "#ea580c",
	red: "#dc2626",
	purple: "#7c3aed",
	pink: "#db2777",
	teal: "#0d9488",
	indigo: "#4f46e5",
	mint: "#10b981",
	lime: "#65a30d",
	amber: "#d97706",
	brown: "#78350f",
	slate: "#475569"
};

export function accentHex(color: string | undefined): string {
	return (color && ACCENT_COLORS[color]) || ACCENT_COLORS.slate!;
}

/**
 * True when every crosspoint in the list is currently live on the router.
 *
 * Deliberately all-or-nothing: a key that drives four destinations is only
 * "on" when all four are where it put them. Lighting it when one matches would
 * tell the operator a route is in place that is not.
 */
export function isLive(crosspoints: Crosspoint[], routes: Record<string, number>): boolean {
	if (crosspoints.length === 0) {
		return false;
	}
	return crosspoints.every((crosspoint) => routes[String(crosspoint.output)] === crosspoint.input);
}
