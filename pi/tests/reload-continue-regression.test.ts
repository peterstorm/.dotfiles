// Repair regression pin for review finding silent-failure-hunter-1 (run
// reload-autocontinue-review-20261116): a pending auto-continue marker must be
// consumed by the first reason-"reload" session start regardless of its age.
// Historical RED against the reviewed state: shouldReloadAutoContinue took
// (entries, now), gated on now - ts <= 60_000 (PENDING_FRESH_MS), and returned
// false for an aged pending marker — while the deferred /reload-runtime
// dispatch only fires after the whole calling run settles, so any wall-clock
// window excludes the feature's primary path.
import { describe, expect, it } from "bun:test";
import {
	RELOAD_CONTINUE_CUSTOM_TYPE,
	parseReloadContinueMarker,
	reloadContinueMarker,
	shouldReloadAutoContinue,
} from "../extensions/reload-runtime";

const entry = (kind: "pending" | "consumed", data: unknown = { kind, ts: 1 }) => ({
	type: "custom",
	customType: RELOAD_CONTINUE_CUSTOM_TYPE,
	data,
});

describe("reload auto-continue regression (silent-failure-hunter-1)", () => {
	it("consumes a pending marker of any age on a reason-reload session start", () => {
		const hourOld = [entry("pending", { kind: "pending", ts: Date.now() - 3_600_000 })];
		expect(shouldReloadAutoContinue(hourOld)).toBe(true);
	});

	it("stays idle when the newest marker is consumed", () => {
		expect(shouldReloadAutoContinue([entry("pending"), entry("consumed", { kind: "consumed", ts: 2 })])).toBe(false);
	});

	it("stays idle with no marker at all", () => {
		expect(shouldReloadAutoContinue([])).toBe(false);
	});

	it("keeps the marker codec total: malformed journal data is never a pending marker", () => {
		expect(parseReloadContinueMarker(reloadContinueMarker("pending"))?.kind).toBe("pending");
		expect(parseReloadContinueMarker("garbage")).toBeUndefined();
		expect(parseReloadContinueMarker({ kind: "other", ts: 5 })).toBeUndefined();
	});
});
