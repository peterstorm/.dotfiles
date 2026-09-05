import { afterEach, describe, expect, test } from "bun:test";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import creativeProjectScope, { creativeSkillPaths, resolveCreativeScope } from "./index";

const temporaryRoots: string[] = [];

const temporaryDirectory = (prefix: string): string => {
	const directory = mkdtempSync(join(tmpdir(), prefix));
	temporaryRoots.push(directory);
	return directory;
};

afterEach(() => {
	delete process.env.PI_CREATIVE_ROOT;
	for (const root of temporaryRoots.splice(0)) {
		rmSync(root, { recursive: true, force: true });
	}
});

describe("creative subtree scope", () => {
	test("includes the creative root and arbitrarily nested descendants", () => {
		const root = temporaryDirectory("pi-creative-root-");
		const nested = join(root, "productions", "pilot", "shots", "001");
		mkdirSync(nested, { recursive: true });

		const rootResult = resolveCreativeScope(root, root);
		const nestedResult = resolveCreativeScope(root, nested);

		expect(rootResult.kind).toBe("inside");
		expect(nestedResult.kind).toBe("inside");
		if (nestedResult.kind === "inside") {
			expect(creativeSkillPaths(nestedResult.scope)).toEqual([join(root, ".pi", "skills")]);
		}
	});

	test("excludes siblings that merely share the root name prefix", () => {
		const parent = temporaryDirectory("pi-creative-parent-");
		const root = join(parent, "creative");
		const sibling = join(parent, "creative-copy");
		mkdirSync(root);
		mkdirSync(sibling);

		expect(resolveCreativeScope(root, sibling).kind).toBe("outside");
	});

	test("fails closed when a symlink inside the tree escapes the canonical root", () => {
		const parent = temporaryDirectory("pi-creative-symlink-");
		const root = join(parent, "creative");
		const outside = join(parent, "outside");
		mkdirSync(root);
		mkdirSync(outside);
		const escaped = join(root, "escaped");
		symlinkSync(outside, escaped, "dir");

		expect(resolveCreativeScope(root, escaped).kind).toBe("outside");
	});

	test("returns an unavailable state instead of guessing for a missing cwd", () => {
		const root = temporaryDirectory("pi-creative-missing-");
		expect(resolveCreativeScope(root, join(root, "missing")).kind).toBe("unavailable");
	});

	test("contributes root skills only to trusted descendant sessions", async () => {
		const root = temporaryDirectory("pi-creative-extension-");
		const nested = join(root, "productions", "pilot");
		mkdirSync(nested, { recursive: true });
		process.env.PI_CREATIVE_ROOT = root;
		const handlers = new Map<string, (event: unknown, context: unknown) => unknown>();
		const pi = {
			on: (name: string, handler: (event: unknown, context: unknown) => unknown) => {
				handlers.set(name, handler);
			},
		} as unknown as ExtensionAPI;
		creativeProjectScope(pi);
		const discover = handlers.get("resources_discover");
		expect(discover).toBeDefined();

		const trusted = await discover?.({}, { cwd: nested, isProjectTrusted: () => true });
		const untrusted = await discover?.({}, { cwd: nested, isProjectTrusted: () => false });
		expect(trusted).toEqual({ skillPaths: [join(root, ".pi", "skills")] });
		expect(untrusted).toBeUndefined();
	});
});
