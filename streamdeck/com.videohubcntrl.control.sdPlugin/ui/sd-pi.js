/**
 * Minimal property-inspector client for the Stream Deck WebSocket API.
 *
 * Written by hand rather than pulling in sdpi-components because that library
 * is fetched from a CDN and this plugin has to configure cleanly on a set
 * network with no internet. It is also a poor fit here: the step editor is a
 * dynamic, nested list, not the flat field-per-setting layout the component
 * library is built around.
 */
(function () {
	"use strict";

	let socket = null;
	let uuid = null;
	let actionUUID = null;
	let settings = {};
	let globalSettings = {};

	const listeners = {
		settings: [],
		globalSettings: [],
		plugin: []
	};

	function emit(kind, value) {
		for (const listener of listeners[kind]) {
			try {
				listener(value);
			} catch (error) {
				console.error(error);
			}
		}
	}

	function send(message) {
		if (socket && socket.readyState === WebSocket.OPEN) {
			socket.send(JSON.stringify(message));
		}
	}

	const api = {
		get settings() {
			return settings;
		},
		get globalSettings() {
			return globalSettings;
		},
		onSettings(listener) {
			listeners.settings.push(listener);
			if (Object.keys(settings).length > 0) {
				listener(settings);
			}
		},
		onGlobalSettings(listener) {
			listeners.globalSettings.push(listener);
		},
		onPluginMessage(listener) {
			listeners.plugin.push(listener);
		},
		setSettings(value) {
			settings = value;
			send({ event: "setSettings", context: uuid, payload: value });
		},
		setGlobalSettings(value) {
			globalSettings = value;
			send({ event: "setGlobalSettings", context: uuid, payload: value });
		},
		sendToPlugin(payload) {
			send({ event: "sendToPlugin", action: actionUUID, context: uuid, payload: payload });
		}
	};

	window.sdpi = api;

	window.connectElgatoStreamDeckSocket = function (
		inPort,
		inPropertyInspectorUUID,
		inRegisterEvent,
		_inInfo,
		inActionInfo
	) {
		uuid = inPropertyInspectorUUID;

		const actionInfo = typeof inActionInfo === "string" ? JSON.parse(inActionInfo) : inActionInfo;
		actionUUID = actionInfo && actionInfo.action;
		settings = (actionInfo && actionInfo.payload && actionInfo.payload.settings) || {};

		socket = new WebSocket("ws://127.0.0.1:" + inPort);

		socket.onopen = function () {
			send({ event: inRegisterEvent, uuid: uuid });
			send({ event: "getGlobalSettings", context: uuid });
			emit("settings", settings);
			// The plugin answers with the current router snapshot, which is
			// what populates every port dropdown in this UI.
			api.sendToPlugin({ request: "snapshot" });
		};

		socket.onmessage = function (message) {
			let data;
			try {
				data = JSON.parse(message.data);
			} catch (error) {
				return;
			}

			if (data.event === "didReceiveSettings") {
				settings = (data.payload && data.payload.settings) || {};
				emit("settings", settings);
			} else if (data.event === "didReceiveGlobalSettings") {
				globalSettings = (data.payload && data.payload.settings) || {};
				emit("globalSettings", globalSettings);
			} else if (data.event === "sendToPropertyInspector") {
				emit("plugin", data.payload || {});
			}
		};
	};
})();
