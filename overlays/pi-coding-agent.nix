final: prev:

{
  pi-coding-agent = prev.buildNpmPackage (finalAttrs: {
    pname = "pi-coding-agent";
    version = "0.83.0";

    src = prev.fetchurl {
      url = "https://registry.npmjs.org/@earendil-works/pi-coding-agent/-/pi-coding-agent-${finalAttrs.version}.tgz";
      hash = "sha256-cJf+Szh2Ldp+x4AB57kEMMhJ+69xcyW/6BCXROMiVeY=";
    };

    npmDepsHash = "sha256-S2mAnU0pf3U3gSgNYEkudNIvxpSI4nior2m0R27O+3E=";

    postPatch = ''
      substituteInPlace npm-shrinkwrap.json \
        --replace-fail '"resolved": "https://registry.npmjs.org/@earendil-works/pi-agent-core/-/pi-agent-core-0.83.0.tgz",' '"resolved": "https://registry.npmjs.org/@earendil-works/pi-agent-core/-/pi-agent-core-0.83.0.tgz",
			"integrity": "sha512-RorGp9OH5l3ElpuC5a5ZQ2eWcchZGXflXRzVGkV99y3y6tT+LLNyxoYIdVKvTKWEObwhExeQbTH0fI2tE4iX4g==",' \
        --replace-fail '"resolved": "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.83.0.tgz",' '"resolved": "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-0.83.0.tgz",
			"integrity": "sha512-m3IZD4g3er0V8TC9+Vpgw/sjTKqcJlkcIBy/JvsgRubuuik3tAVzyugUg4rVrShIkkOT69mEd34NEqKUIsl6JQ==",' \
        --replace-fail '"resolved": "https://registry.npmjs.org/@earendil-works/pi-tui/-/pi-tui-0.83.0.tgz",' '"resolved": "https://registry.npmjs.org/@earendil-works/pi-tui/-/pi-tui-0.83.0.tgz",
			"integrity": "sha512-IoYrb0rORjELmEpNtoCA/U8je3KopMkRAVJRdSzvXRvgb+Huo1gNh8Q5CSZvNOiYtDxJdj2tYZZHZ4B3+IN3hA==",'

      substituteInPlace package.json \
        --replace-fail '	},
	"devDependencies": {
		"@types/cross-spawn": "6.0.6",
		"@types/diff": "7.0.2",
		"@types/hosted-git-info": "3.0.5",
		"@types/ms": "2.1.0",
		"@types/node": "24.12.4",
		"@types/proper-lockfile": "4.1.4",
		"@types/semver": "7.7.1",
		"shx": "0.4.0",
		"typescript": "5.9.3",
		"vitest": "4.1.9"
	},
	"keywords": [' '	},
	"keywords": ['
    '';

    npmDepsFetcherVersion = 2;

    dontNpmBuild = true;

    npmFlags = [ "--omit=dev" ];
    npmInstallFlags = [ "--omit=dev" ];
    npmRebuildFlags = [ "--ignore-scripts" ];

    nativeBuildInputs = [
      prev.makeBinaryWrapper
    ];

    postFixup = "wrapProgram $out/bin/pi --prefix PATH : ${prev.lib.makeBinPath [ prev.ripgrep ]}";

    doInstallCheck = true;
    nativeInstallCheckInputs = [
      prev.writableTmpDirAsHomeHook
      prev.versionCheckHook
    ];
    versionCheckKeepEnvironment = [ "HOME" ];
    versionCheckProgram = "${placeholder "out"}/bin/pi";
    versionCheckProgramArg = "--version";

    meta = {
      description = "Coding agent CLI with read, bash, edit, write tools and session management";
      homepage = "https://pi.dev/";
      license = prev.lib.licenses.mit;
      mainProgram = "pi";
    };
  });
}
