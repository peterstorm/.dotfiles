import { describe, expect, it } from "bun:test";
import { formatToolCall, mapWithConcurrencyLimit } from "./index";

// Uncoloured theme: the text a formatter produces, without escape codes.
const plain = (_color: unknown, text: string): string => text;

describe("mapWithConcurrencyLimit", () => {
	it("never runs more than its limit at once, and keeps results in input order", async () => {
		for (const limit of [1, 3, 8]) {
			let running = 0;
			let peak = 0;
			const results = await mapWithConcurrencyLimit([...Array(10).keys()], limit, async (item) => {
				running++;
				peak = Math.max(peak, running);
				await new Promise((resolve) => setTimeout(resolve, 5 + (item % 3)));
				running--;
				return item * 2;
			});
			expect(peak).toBe(limit);
			expect(results).toEqual([...Array(10).keys()].map((item) => item * 2));
		}
	});

	it("runs nothing for no items and at least one worker for a non-positive limit", async () => {
		expect(await mapWithConcurrencyLimit([], 4, async () => 1)).toEqual([]);
		expect(await mapWithConcurrencyLimit([1, 2], 0, async (item) => item)).toEqual([1, 2]);
	});
});

describe("formatToolCall", () => {
	it("formats known tools with their named formatter", () => {
		expect(formatToolCall("bash", { command: "ls -la" }, plain)).toBe("$ ls -la");
		expect(formatToolCall("read", { path: "/etc/hosts", offset: 10, limit: 5 }, plain)).toBe("read /etc/hosts:10-14");
		expect(formatToolCall("grep", { pattern: "TODO", path: "/srv" }, plain)).toBe("grep /TODO/ in /srv");
	});

	it("previews any other tool as JSON, including Object.prototype names", () => {
		expect(formatToolCall("web_search", { q: "pi" }, plain)).toBe('web_search {"q":"pi"}');
		for (const name of ["constructor", "toString", "hasOwnProperty", "__proto__"]) {
			expect(formatToolCall(name, { a: 1 }, plain)).toBe(`${name} {"a":1}`);
		}
	});
});
