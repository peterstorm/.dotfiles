import { extname } from "node:path";

/** Extensions treated as implementation code by the Loom rules gate. */
export const CODE_EXTENSIONS: ReadonlySet<string> = new Set([
	".ts",
	".tsx",
	".js",
	".jsx",
	".mjs",
	".cjs",
	".mts",
	".cts",
	".java",
	".rs",
	".kt",
	".scala",
	".py",
	".go",
	".rb",
	".php",
	".c",
	".h",
	".cpp",
	".cc",
	".cxx",
	".hpp",
	".cs",
	".swift",
	".sh",
	".zsh",
	".bash",
	".vue",
	".svelte",
]);

const MUTATOR_COMMANDS = new Set(["cp", "mv", "patch", "rsync", "install", "tee"]);
const CHAIN_BOUNDARY = /&&|\|\||;|\n/;
const TOKEN = /"[^"]*"|'[^']*'|[^\s]+/g;
const REDIRECT_TARGET = /(?:^|\s)(?:\d*)>>?\s*("[^"]+"|'[^']+'|[^\s|;&>]+)/g;

function normalizeToken(raw: string): string {
	return raw
		.replace(/^["'`]+|["'`,]+$/g, "")
		.replace(/[)]*$/g, "");
}

function isCodePath(token: string): boolean {
	return CODE_EXTENSIONS.has(extname(normalizeToken(token)).toLowerCase());
}

function tokensOf(segment: string): readonly string[] {
	return [...segment.matchAll(TOKEN)].map((match) => normalizeToken(match[0])).filter(Boolean);
}

function commandName(token: string): string {
	const normalized = normalizeToken(token);
	return normalized.slice(normalized.lastIndexOf("/") + 1);
}

function redirectionTarget(segment: string): string | null {
	REDIRECT_TARGET.lastIndex = 0;
	for (const match of segment.matchAll(REDIRECT_TARGET)) {
		const target = normalizeToken(match[1] ?? "");
		if (isCodePath(target)) return target;
	}
	return null;
}

function mutatorTarget(segment: string): string | null {
	const tokens = tokensOf(segment);
	const mutatorIndex = tokens.findIndex((token, index) => {
		const name = commandName(token);
		if (MUTATOR_COMMANDS.has(name)) return true;
		return name === "sed" && tokens.slice(index + 1).some((candidate) => /^-[^-]*i/.test(candidate));
	});
	if (mutatorIndex < 0) return null;

	const argumentsAfterMutator = tokens.slice(mutatorIndex + 1);
	const codeArguments = argumentsAfterMutator.filter(isCodePath);
	if (codeArguments.length === 0) return null;

	const mutator = commandName(tokens[mutatorIndex] ?? "");
	if (["cp", "mv", "rsync", "install", "sed"].includes(mutator)) {
		return codeArguments.at(-1) ?? null;
	}
	return codeArguments[0] ?? null;
}

/**
 * Return the first code path targeted by a recognized Bash mutation.
 *
 * Mutation evidence is chain-local: a mutator in one `&&`/`||`/`;` command
 * cannot borrow a `.ts` argument from a later read-only command. Pipes remain
 * within one segment so `cat patch.diff | patch src/file.ts` stays gated.
 */
export function firstBashCodeMutationTarget(command: string): string | null {
	for (const segment of command.split(CHAIN_BOUNDARY)) {
		const redirected = redirectionTarget(segment);
		if (redirected !== null) return redirected;
		const mutated = mutatorTarget(segment);
		if (mutated !== null) return mutated;
	}
	return null;
}
