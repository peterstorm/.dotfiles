# VS Code Insiders

Installed via overlay at `overlays/vscode-insiders.nix`.

## Updating

Hash needs updating when new versions release:

```bash
nix-prefetch-url --name vscode-insiders.zip "https://code.visualstudio.com/sha/download?build=insider&os=darwin-arm64"
```

Update sha256 in `overlays/vscode-insiders.nix`, then rebuild:

```bash
./hm-apply.sh
```
