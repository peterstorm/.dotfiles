final: prev:

let
  inherit (prev) stdenv;

  platformInfo = {
    "aarch64-darwin" = {
      os = "darwin-arm64";
      sha256 = "1909ldq5n418mh89y7ihf76zgzz25zxwxparlpi064p3pja7mhx3";
      archive = "zip";
    };
    "x86_64-darwin" = {
      os = "darwin";
      sha256 = "0000000000000000000000000000000000000000000000000000"; # update when needed
      archive = "zip";
    };
    "x86_64-linux" = {
      os = "linux-x64";
      sha256 = "0000000000000000000000000000000000000000000000000000"; # update when needed
      archive = "tar.gz";
    };
    "aarch64-linux" = {
      os = "linux-arm64";
      sha256 = "0000000000000000000000000000000000000000000000000000"; # update when needed
      archive = "tar.gz";
    };
  };

  info = platformInfo.${stdenv.system} or (throw "Unsupported system: ${stdenv.system}");

  darwinInstallPhase = ''
    mkdir -p "$out/Applications" "$out/bin"
    unzip -q "$src" -d "$out/Applications"
    chmod +x "$out/Applications/Visual Studio Code - Insiders.app/Contents/MacOS/"*
    chmod +x "$out/Applications/Visual Studio Code - Insiders.app/Contents/Frameworks/"*.framework/Versions/A/*
    ln -s "$out/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" "$out/bin/code"
  '';

  linuxInstallPhase = ''
    mkdir -p "$out/lib/vscode" "$out/bin"
    tar -xzf "$src" --strip-components=1 -C "$out/lib/vscode"
    ln -s "$out/lib/vscode/bin/code-insiders" "$out/bin/code"
    ln -s "$out/lib/vscode/bin/code-insiders" "$out/bin/code-insiders"
  '';

in {
  vscode-insiders = (prev.vscode.override {
    isInsiders = true;
  }).overrideAttrs (oldAttrs: {
    pname = "vscode-insiders";
    version = "latest";
    src = prev.fetchurl {
      url = "https://code.visualstudio.com/sha/download?build=insider&os=${info.os}";
      sha256 = info.sha256;
      name = "vscode-insiders.${info.archive}";
    };
    installPhase = if stdenv.isDarwin then darwinInstallPhase else linuxInstallPhase;
  });
}
