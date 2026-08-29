import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const EXTENSIONS_DIR = join(import.meta.dir, "extensions");

describe("Pi root extension discovery", () => {
	for (const name of readdirSync(EXTENSIONS_DIR).filter((entry) => entry.endsWith(".ts")).sort()) {
		it(`${name} exports an extension factory`, () => {
			const source = readFileSync(join(EXTENSIONS_DIR, name), "utf8");
			expect(source).toMatch(/\bexport\s+default\s+function\b/);
		});
	}
});
