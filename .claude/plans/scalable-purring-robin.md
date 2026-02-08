# Plan: Obsidian Vault Git Sync via Home-Manager Systemd Timer

## Context
peterstorm on homelab is headless. Need Obsidian vault (`git@github.com:peterstorm/obsidian.git`) auto-synced via git. No separate HM config needed - add role to existing peterstorm config.

## Changes

### 1. New role: `roles/home-manager/obsidian-git-sync/default.nix`

Systemd user service + timer:
- Pull remote, commit local changes, push
- Every 5 minutes
- Script uses git pull --rebase --autostash for clean merges
- Vault path: `~/dev/notes/remotevault`

### 2. Update `flake.nix`

Add `"obsidian-git-sync"` to peterstorm's roles list.

## Files
- `roles/home-manager/obsidian-git-sync/default.nix` - **new**
- `flake.nix` - add role to peterstorm

## Verification
1. `nix build .#homeManagerConfigurations.peterstorm.activationPackage --dry-run`
2. On homelab: `./hm-apply.sh`, then `systemctl --user status obsidian-git-sync.timer`
3. Manual test: `systemctl --user start obsidian-git-sync.service`
