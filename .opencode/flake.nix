{
  description = "OpenCode plugins development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            bun
            nodejs_22
            typescript
          ];

          shellHook = ''
            echo "OpenCode plugin development environment"
            echo "Available tools: bun, node, npm, tsc"
            echo ""
            echo "To build the task-planner plugin:"
            echo "  cd plugins/task-planner && bun install && bun run build"
          '';
        };
      }
    );
}
