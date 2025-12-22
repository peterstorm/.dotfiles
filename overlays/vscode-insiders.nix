final: prev: {
  vscode-insiders = (prev.vscode.override {
    isInsiders = true;
  }).overrideAttrs (oldAttrs: rec {
    pname = "vscode-insiders";
    version = "latest";
    src = prev.fetchurl {
      url = "https://code.visualstudio.com/sha/download?build=insider&os=darwin-arm64";
      sha256 = "0nf0wn93h9p27mb9hhaa8j7cjyarrjxi5l2ph5mbm7vnzpv77acl";
      name = "vscode-insiders.zip";
    };
    installPhase = ''
      mkdir -p "$out/Applications" "$out/bin"
      unzip -q "$src" -d "$out/Applications"
      chmod +x "$out/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/"*
      chmod +x "$out/Applications/Visual Studio Code - Insiders.app/Contents/Frameworks/"*.framework/Versions/A/*

      # Create code CLI wrapper
      ln -s "$out/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" "$out/bin/code"
    '';
  });
}
