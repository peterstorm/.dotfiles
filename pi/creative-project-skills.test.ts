import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	DefaultResourceLoader,
	SettingsManager,
	type Skill,
} from "@earendil-works/pi-coding-agent";

const creativeSkillNames = Object.freeze([
	"banana-pro-director-30",
	"character-builder",
	"cinema-director",
	"story-bible-builder",
]);

const temporaryRoots: string[] = [];

const temporaryDirectory = (prefix: string): string => {
	const directory = mkdtempSync(join(tmpdir(), prefix));
	temporaryRoots.push(directory);
	return directory;
};

const deployCreativeSkills = (projectRoot: string): void => {
	const sourceRoot = temporaryDirectory("pi-creative-sources-");
	const projectSkillsRoot = join(projectRoot, ".pi", "skills");
	mkdirSync(projectSkillsRoot, { recursive: true });
	for (const name of creativeSkillNames) {
		const source = join(sourceRoot, name);
		mkdirSync(source);
		writeFileSync(
			join(source, "SKILL.md"),
			`---\nname: ${name}\ndescription: Test fixture for ${name}.\n---\n`,
		);
		symlinkSync(source, join(projectSkillsRoot, name), "dir");
	}
};

const creativeSkillsFrom = (skills: readonly Skill[]): readonly Skill[] =>
	skills.filter(({ name }) => creativeSkillNames.includes(name));

const discover = async (
	cwd: string,
	agentDir: string,
	projectTrusted = true,
): Promise<ReturnType<DefaultResourceLoader["getSkills"]>> => {
	const settingsManager = SettingsManager.inMemory({}, { projectTrusted });
	const loader = new DefaultResourceLoader({
		cwd,
		agentDir,
		settingsManager,
		noExtensions: true,
		noPromptTemplates: true,
		noThemes: true,
		noContextFiles: true,
	});
	await loader.reload();
	return loader.getSkills();
};

afterEach(() => {
	for (const root of temporaryRoots.splice(0)) {
		rmSync(root, { recursive: true, force: true });
	}
});

describe("creative project skill scope", () => {
	test("discovers all four skills from the creative project root", async () => {
		const projectRoot = temporaryDirectory("pi-creative-project-");
		const agentDir = temporaryDirectory("pi-creative-agent-");
		deployCreativeSkills(projectRoot);

		const result = await discover(projectRoot, agentDir);

		expect(creativeSkillsFrom(result.skills).map(({ name }) => name).sort()).toEqual(
			[...creativeSkillNames].sort(),
		);
		expect(
			result.diagnostics.filter(({ path }) => path?.startsWith(projectRoot)),
		).toEqual([]);
	});

	test("does not discover the creative skills from nested or sibling directories", async () => {
		const creativeProject = temporaryDirectory("pi-creative-project-");
		const nestedDirectory = join(creativeProject, "productions", "pilot");
		const siblingProject = temporaryDirectory("pi-unrelated-project-");
		const agentDir = temporaryDirectory("pi-creative-agent-");
		mkdirSync(nestedDirectory, { recursive: true });
		deployCreativeSkills(creativeProject);

		for (const cwd of [nestedDirectory, siblingProject]) {
			const result = await discover(cwd, agentDir);
			expect(creativeSkillsFrom(result.skills)).toEqual([]);
		}
	});

	test("does not load project skills before the project is trusted", async () => {
		const creativeProject = temporaryDirectory("pi-creative-project-");
		const agentDir = temporaryDirectory("pi-creative-agent-");
		deployCreativeSkills(creativeProject);

		const result = await discover(creativeProject, agentDir, false);

		expect(creativeSkillsFrom(result.skills)).toEqual([]);
	});
});
