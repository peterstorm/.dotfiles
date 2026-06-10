final: prev:

{
  pi-coding-agent = prev.buildNpmPackage (finalAttrs: {
    pname = "pi-coding-agent";
    version = "0.75.4";

    src = prev.fetchFromGitHub {
      owner = "earendil-works";
      repo = "pi";
      tag = "v${finalAttrs.version}";
      hash = "sha256-zyIgs2N7uVz+7E+NqxH78baRw0OwXvlrjZiDIP/v0M4=";
    };

    npmDepsHash = "sha256-5Vl+0BBUS7Rtb6XqpGKbbNMyh+9UX2aAsgtn60QLX7A=";

    npmWorkspace = "packages/coding-agent";

    npmRebuildFlags = [ "--ignore-scripts" ];

    nativeBuildInputs = [
      prev.makeBinaryWrapper
    ];

    buildPhase = ''
      runHook preBuild

      npx tsgo -p packages/ai/tsconfig.build.json
      npx tsgo -p packages/tui/tsconfig.build.json
      npx tsgo -p packages/agent/tsconfig.build.json
      npm run build --workspace=packages/coding-agent

      runHook postBuild
    '';

    postInstall = ''
      local nm="$out/lib/node_modules/pi-monorepo/node_modules"

      for ws in @earendil-works/pi-ai:packages/ai \
                @earendil-works/pi-agent-core:packages/agent \
                @earendil-works/pi-tui:packages/tui; do
        IFS=: read -r pkg src <<< "$ws"
        rm "$nm/$pkg"
        cp -r "$src" "$nm/$pkg"
      done

      find "$nm" -type l -lname '*/packages/*' -delete
      find "$nm/.bin" -xtype l -delete
    '';
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
