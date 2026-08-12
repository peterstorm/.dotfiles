import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { loadModelRoutingPolicy } from "./config.js";

/** Validate the shared routing policy when extensions load; subagent execution reloads and snapshots it. */
export default function modelRoutingExtension(_pi: ExtensionAPI) {
	const loaded = loadModelRoutingPolicy();
	if (!loaded.ok) {
		console.error(`Cannot load Pi model routing policy ${loaded.error.path}:\n${loaded.error.message}`);
	}
}
