# New Desktop (AI Workstation) — NixOS Install Guide

Target machine: AMD Ryzen + 2× NVIDIA RTX 6000 Pro (Blackwell), WiFi + Ethernet, single NVMe, ZFS root, KDE Plasma dual-monitor.

Host name: `desktop`. Everything is declarative — one command from the laptop wipes and installs.

## What's already in the flake

- `flake.nix`
  - `disko` input added (`github:nix-community/disko`)
  - Top-level `flake.nixosConfigurations` / `homeConfigurations` (so `nixos-anywhere` and `nixos-rebuild` find the host by name)
  - `desktop` host:
    - Kernel: `pkgs.linuxPackages` (6.18+, ZFS-compatible, supports Blackwell)
    - User `peterstorm` in `wheel`, `networkmanager`, `docker`, `video`, `render`
    - `cpuCores = 16`
- `machines/desktop/disks.nix` — declarative disko layout
  - 1 GiB EFI (vfat) at `/boot`
  - Rest as ZFS pool `rpool` (ashift=12, zstd, atime=off, xattr=sa, acltype=posixacl)
  - Datasets: `root` → `/`, `nix` → `/nix`, `home` → `/home`, `docker` → `/var/lib/docker`, `models` → `/models` (recordsize=1M, compression=off for pre-compressed weights)
- `machines/desktop/default.nix`
  - Imports disko + `disks.nix`
  - `boot.supportedFilesystems = [ "zfs" ]`
  - `networking.hostId = "8a3f2c19"`
  - `zramSwap` enabled (50% RAM, zstd) — no on-disk swap
  - Auto-scrub + TRIM
  - AMD microcode
- `roles/nvidia-graphics/default.nix` — rewritten for Blackwell
  - `hardware.nvidia.open = true` (required — Blackwell only supports the open kernel module)
  - `production` driver channel
  - `nvidiaPersistenced = true` (stable CUDA workloads)
  - `powerManagement.enable = false` (workstation, always on)
  - `hardware.nvidia-container-toolkit.enable = true` (Docker GPU passthrough)
  - `nvtopPackages.nvidia` in system packages

## Tunables before you run

Read these once before `nixos-anywhere` — they're the only places hardware assumptions leak in.

| File | Setting | Current | When to change |
|---|---|---|---|
| `machines/desktop/disks.nix` | `diskDevice` | `/dev/nvme0n1` | If target NVMe isn't the first slot, or prefer `/dev/disk/by-id/nvme-...` |
| `flake.nix` (desktop) | `NICs` | `[ "wlp5s0" "enp6s0" ]` | Update once you know real interface names (`ip -o link show`). Non-blocking — NetworkManager handles the rest |
| `machines/desktop/default.nix` | `networking.hostId` | `"8a3f2c19"` | Only if it collides with an existing host |
| `flake.nix` (desktop) | `cpuCores` | `16` | Set to actual core count for build parallelism |

## Prerequisites (one-time, on your laptop)

- Nix with flakes: `experimental-features = nix-command flakes` in `~/.config/nix/nix.conf` (already set in dotfiles)
- SSH key ready — you'll use it to reach the new box during bootstrap

## Step 1 — Write the NixOS live ISO to a USB

```bash
# From your laptop, with USB inserted (verify with lsblk)
curl -fLO https://channels.nixos.org/nixos-unstable/latest-nixos-minimal-x86_64-linux.iso
sudo dd if=latest-nixos-minimal-x86_64-linux.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Replace `/dev/sdX` with the actual USB device. Double-check with `lsblk` before running.

## Step 2 — Boot the new desktop from USB (only time it needs a monitor)

- BIOS: UEFI mode, Secure Boot **off**, boot from USB.
- At the shell prompt (auto-login as `nixos`):

```bash
sudo systemctl start sshd
sudo passwd nixos              # set a temp password so nixos-anywhere can SSH in
ip addr                        # note the IP
lsblk                          # confirm target disk (should be /dev/nvme0n1)
```

Optional — check the actual NIC names now so you can update `flake.nix` later:

```bash
ip -o link show
```

Unplug the monitor after this if you want. Everything else is remote.

## Step 3 — Install remotely with nixos-anywhere (from your laptop)

```bash
cd ~/.dotfiles

# Sanity check — should print "desktop"
nix eval .#nixosConfigurations.desktop.config.networking.hostName

# The install — this wipes /dev/nvme0n1 on the target
nix run github:nix-community/nixos-anywhere -- \
  --flake .#desktop \
  --target-host nixos@<new-desktop-ip>
```

What happens:
1. SSH into the ISO as `nixos`
2. Kexec into a fresh NixOS installer image
3. Partition + create ZFS pool per `machines/desktop/disks.nix`
4. Build the closure on your laptop (fastest) and copy it over
5. Install bootloader + system
6. Reboot

Expect 15–30 minutes on the first run — mostly NVIDIA driver + kernel build. Cached on repeat.

## Step 4 — Post-install setup

Once the machine reboots into the installed system:

```bash
# From your laptop
ssh root@<new-desktop-ip>            # ISO's root password, if you set one, or key-based
passwd peterstorm                    # set your user password
```

Copy your dotfiles and age key:

```bash
# From your laptop
scp -r ~/.dotfiles peterstorm@<new-desktop-ip>:~/
scp ~/.config/sops/age/keys.txt peterstorm@<new-desktop-ip>:~/.config/sops/age/keys.txt
ssh peterstorm@<new-desktop-ip> chmod 600 ~/.config/sops/age/keys.txt
```

Apply home-manager:

```bash
ssh peterstorm@<new-desktop-ip>
cd ~/.dotfiles && ./hm-apply.sh
```

## Step 5 — Verify

```bash
nvidia-smi                                                                       # both RTX 6000 Pro cards listed
nvtop                                                                            # live view
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi        # container GPU passthrough
zpool status                                                                     # rpool ONLINE, all datasets mounted
zfs list                                                                         # confirm root/nix/home/docker/models
```

## Re-running

`nixos-anywhere` is idempotent for the same disk layout. To iterate on the config after install, use the normal flow:

```bash
ssh peterstorm@desktop
cd ~/.dotfiles
./system-apply.sh switch
```

To wipe and reinstall from scratch (destructive!), boot the USB again and re-run `nixos-anywhere`.

## Notes

- **ZFS + Blackwell + latest kernel** — `pkgs.linuxPackages` currently resolves to 6.18, which supports both. If ZFS falls behind mainline in future, pin to an LTS: `kernelPackage = pkgs.linuxPackages_6_12;`.
- **CUDA on host** — deliberately not installed. Use `nvidia/cuda:*` containers for compilation and inference; keeps host lean.
- **Model storage** — `/models` is a dedicated ZFS dataset with 1M recordsize and no compression, tuned for large safetensors/GGUF files. Put HuggingFace cache, Ollama models, etc. there.
- **Fan control** — the old motherboard-specific `hardware.fancontrol` block is gone. If the new board needs custom curves, generate config with `pwmconfig` after boot and add it back to `machines/desktop/default.nix`.
