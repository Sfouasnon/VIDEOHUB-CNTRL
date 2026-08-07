import { Socket } from "node:net";
import streamDeck from "@elgato/streamdeck";

import { DEFAULT_PORT, PROTOCOL_VERSION, type Crosspoint, type ServerEvent, type Snapshot } from "./protocol";

type SnapshotListener = (snapshot: Snapshot | null) => void;

type PendingCommand = {
	resolve: (error: string | null) => void;
	timer: NodeJS.Timeout;
};

/**
 * The plugin's single connection to Videohub On-Set.
 *
 * One connection is shared by every key, because the interesting state — which
 * source is on which destination — is global to the router. Per-key
 * connections would multiply reconnect storms when the app restarts and give
 * each key its own, potentially stale, view of the same routes.
 *
 * The app is expected to come and go: it is a desktop app on a cart that gets
 * quit, and the deck stays powered. So this reconnects indefinitely with a
 * bounded backoff and reports "app not running" rather than treating a closed
 * socket as an error worth surfacing on every key.
 */
class Bridge {
	/** Same ladder as the app uses toward the router, for the same reason. */
	private static readonly RECONNECT_DELAYS_MS = [500, 1000, 2000, 4000, 8000];
	private static readonly COMMAND_TIMEOUT_MS = 5000;

	private socket: Socket | null = null;
	private buffer = "";
	private attempt = 0;
	private reconnectTimer: NodeJS.Timeout | null = null;
	private shuttingDown = false;
	private nextRequestID = 1;
	private readonly pending = new Map<string, PendingCommand>();
	private readonly listeners = new Set<SnapshotListener>();

	private _port = DEFAULT_PORT;
	private _snapshot: Snapshot | null = null;
	private _connected = false;

	get snapshot(): Snapshot | null {
		return this._snapshot;
	}

	get connected(): boolean {
		return this._connected;
	}

	get port(): number {
		return this._port;
	}

	/** Called when global settings change the port; reconnects if it moved. */
	setPort(port: number): void {
		if (!Number.isInteger(port) || port < 1 || port > 65535 || port === this._port) {
			return;
		}
		this._port = port;
		this.disconnect();
		this.connect();
	}

	onSnapshot(listener: SnapshotListener): () => void {
		this.listeners.add(listener);
		listener(this._snapshot);
		return () => this.listeners.delete(listener);
	}

	connect(): void {
		if (this.shuttingDown || this.socket) {
			return;
		}
		this.clearReconnectTimer();

		const socket = new Socket();
		this.socket = socket;
		socket.setNoDelay(true);

		socket.on("connect", () => {
			this.attempt = 0;
			this._connected = true;
			streamDeck.logger.info(`Connected to Videohub On-Set on 127.0.0.1:${this._port}`);
		});

		socket.on("data", (chunk) => this.consume(chunk));

		socket.on("error", (error) => {
			// A refused connection is the normal state when the app is not
			// running, so it is logged at debug rather than error to keep the
			// log usable when something genuinely breaks.
			streamDeck.logger.debug(`Control connection error: ${error.message}`);
		});

		socket.on("close", () => {
			this.socket = null;
			this._connected = false;
			this.buffer = "";
			this.failAllPending("Videohub On-Set is not running");
			this.publish(null);
			this.scheduleReconnect();
		});

		socket.connect({ host: "127.0.0.1", port: this._port });
	}

	disconnect(): void {
		this.clearReconnectTimer();
		const socket = this.socket;
		this.socket = null;
		this._connected = false;
		socket?.destroy();
	}

	shutdown(): void {
		this.shuttingDown = true;
		this.disconnect();
	}

	private scheduleReconnect(): void {
		if (this.shuttingDown || this.reconnectTimer) {
			return;
		}
		const index = Math.min(this.attempt, Bridge.RECONNECT_DELAYS_MS.length - 1);
		const delay = Bridge.RECONNECT_DELAYS_MS[index]!;
		this.attempt += 1;
		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = null;
			this.connect();
		}, delay);
	}

	private clearReconnectTimer(): void {
		if (this.reconnectTimer) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}
	}

	// MARK: - Framing

	private consume(chunk: Buffer): void {
		this.buffer += chunk.toString("utf8");
		let newlineIndex = this.buffer.indexOf("\n");
		while (newlineIndex >= 0) {
			const line = this.buffer.slice(0, newlineIndex);
			this.buffer = this.buffer.slice(newlineIndex + 1);
			if (line.trim().length > 0) {
				this.handleLine(line);
			}
			newlineIndex = this.buffer.indexOf("\n");
		}
	}

	private handleLine(line: string): void {
		let event: ServerEvent;
		try {
			event = JSON.parse(line) as ServerEvent;
		} catch {
			streamDeck.logger.warn("Discarded unparseable frame from Videohub On-Set");
			return;
		}

		switch (event.type) {
			case "hello":
				if (event.protocolVersion !== PROTOCOL_VERSION) {
					// Refusing is deliberate. Guessing at a changed wire format
					// risks routing the wrong source, which is worse on set
					// than a plugin that visibly does nothing.
					streamDeck.logger.error(
						`Videohub On-Set speaks protocol ${event.protocolVersion}, this plugin speaks ${PROTOCOL_VERSION}. Update whichever is older.`
					);
					this.shutdown();
				}
				break;

			case "snapshot":
				this._snapshot = event.snapshot;
				this.publish(event.snapshot);
				break;

			case "ack": {
				const pending = this.pending.get(event.id);
				if (pending) {
					this.pending.delete(event.id);
					clearTimeout(pending.timer);
					pending.resolve(event.ok ? null : (event.error ?? "Refused"));
				}
				break;
			}

			case "notice":
				streamDeck.logger.info(`Videohub On-Set: ${event.message}`);
				break;
		}
	}

	private publish(snapshot: Snapshot | null): void {
		if (snapshot === null) {
			this._snapshot = null;
		}
		for (const listener of this.listeners) {
			try {
				listener(snapshot);
			} catch (error) {
				streamDeck.logger.error(`Snapshot listener threw: ${String(error)}`);
			}
		}
	}

	// MARK: - Commands

	/** Resolves with `null` on success, or the reason the app refused. */
	route(crosspoints: Crosspoint[]): Promise<string | null> {
		if (crosspoints.length === 0) {
			return Promise.resolve("This key has no crosspoints configured");
		}
		return this.send({ type: "route", crosspoints });
	}

	fireSalvo(salvoID: string): Promise<string | null> {
		return this.send({ type: "salvo", salvoID });
	}

	refresh(): Promise<string | null> {
		return this.send({ type: "refresh" });
	}

	private send(payload: Record<string, unknown>): Promise<string | null> {
		const socket = this.socket;
		if (!socket || !this._connected) {
			return Promise.resolve("Videohub On-Set is not running");
		}

		const id = String(this.nextRequestID++);
		return new Promise<string | null>((resolve) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				resolve("Videohub On-Set did not respond");
			}, Bridge.COMMAND_TIMEOUT_MS);

			this.pending.set(id, { resolve, timer });
			socket.write(`${JSON.stringify({ ...payload, id })}\n`, (error) => {
				if (!error) {
					return;
				}
				const entry = this.pending.get(id);
				if (entry) {
					this.pending.delete(id);
					clearTimeout(entry.timer);
					resolve("Could not reach Videohub On-Set");
				}
			});
		});
	}

	private failAllPending(reason: string): void {
		for (const [, entry] of this.pending) {
			clearTimeout(entry.timer);
			entry.resolve(reason);
		}
		this.pending.clear();
	}
}

/** One bridge per plugin process, shared by every action instance. */
export const bridge = new Bridge();
