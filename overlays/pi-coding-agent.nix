final: prev:

{
  pi-coding-agent = prev.buildNpmPackage (finalAttrs: {
    pname = "pi-coding-agent";
    version = "0.74.0";

    src = prev.fetchFromGitHub {
      owner = "badlogic";
      repo = "pi-mono";
      tag = "v${finalAttrs.version}";
      hash = "sha256-wEiqOezD8w08vyuenh3Kk+YCYBbQoEq67wATDEKy5XM=";
    };

    npmDepsHash = "sha256-zu4cTy/DGdGu1BV4VDY5xiHTcAyUMgmroRaRaKis/p4=";

    # The 0.74.0 lockfile is missing `resolved` and `integrity` fields.
    # Replace it with a pre-patched version that has full metadata.
    postPatch = ''
      cp ${./pi-coding-agent-0.74.0-package-lock.json} package-lock.json
    '';

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
