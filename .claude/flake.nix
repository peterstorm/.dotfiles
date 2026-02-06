{
  description = "Dev shell for loom hooks (ts-utils)";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      forAllSystems = f: nixpkgs.lib.genAttrs
        [ "x86_64-linux" "aarch64-darwin" ]
        (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            bun
            jq
          ];
          shellHook = ''
            echo "loom dev shell — bun $(bun --version), jq $(jq --version)"
          '';
        };
      });
    };
}
