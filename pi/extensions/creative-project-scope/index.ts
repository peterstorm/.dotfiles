import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve } from "node:path";
import { pathToFileURL } from "node:url";

type CreativeScope = Readonly<{
	root: string;
	cwd: string;
}>;

type ScopeResult =
	| Readonly<{ kind: "inside"; scope: CreativeScope }>
	| Readonly<{ kind: "outside"; root: string; cwd: string }>
	| Readonly<{ kind: "unavailable"; message: string }>;

type McpAdapterModule = Readonly<{
	createMcpAdapter: (options: Readonly<{ configPath: string }>) => (pi: ExtensionAPI) => void | Promise<void>;
}>;

const canonical = (path: string): string => realpathSync(resolve(path));

export const creativeRoot = (): string =>
	process.env.PI_CREATIVE_ROOT?.trim() || join(homedir(), "dev", "creative");

export const resolveCreativeScope = (root: string, cwd: string): ScopeResult => {
	try {
		const canonicalRoot = canonical(root);
		const canonicalCwd = canonical(cwd);
		const fromRoot = relative(canonicalRoot, canonicalCwd);
		return fromRoot === "" || (!fromRoot.startsWith("..") && !isAbsolute(fromRoot))
			? { kind: "inside", scope: { root: canonicalRoot, cwd: canonicalCwd } }
			: { kind: "outside", root: canonicalRoot, cwd: canonicalCwd };
	} catch (error) {
		return {
			kind: "unavailable",
			message: error instanceof Error ? error.message : String(error),
		};
	}
};

export const creativeSkillPaths = (scope: CreativeScope): readonly string[] =>
	Object.freeze([join(scope.root, ".pi", "skills")]);

const adapterSource = (scope: CreativeScope): string =>
	join(
		scope.root,
		".pi",
		"git",
		"github.com",
		"nicobailon",
		"pi-mcp-adapter",
		"index.ts",
	);

const loadMcpAdapter = async (scope: CreativeScope): Promise<McpAdapterModule> => {
	const imported = (await import(pathToFileURL(adapterSource(scope)).href)) as Partial<McpAdapterModule>;
	if (typeof imported.createMcpAdapter !== "function") {
		throw new Error("Pinned creative pi-mcp-adapter does not export createMcpAdapter");
	}
	return imported as McpAdapterModule;
};

export default function creativeProjectScope(pi: ExtensionAPI): void {
	let initializedForRoot: string | undefined;

	pi.on("session_start", async (_event, ctx) => {
		const result = resolveCreativeScope(creativeRoot(), ctx.cwd);
		if (result.kind !== "inside" || !ctx.isProjectTrusted()) return;
		if (initializedForRoot === result.scope.root) return;

		const adapter = await loadMcpAdapter(result.scope);
		await adapter.createMcpAdapter({ configPath: join(result.scope.root, ".mcp.json") })(pi);
		initializedForRoot = result.scope.root;
	});

	pi.on("resources_discover", (_event, ctx) => {
		const result = resolveCreativeScope(creativeRoot(), ctx.cwd);
		if (result.kind !== "inside" || !ctx.isProjectTrusted()) return;
		return { skillPaths: [...creativeSkillPaths(result.scope)] };
	});
}
