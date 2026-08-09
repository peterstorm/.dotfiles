# New Desktop (AI Workstation) — NixOS Install Guide

Target machine: AMD Ryzen 9 9950X + 2× NVIDIA RTX PRO 6000 Blackwell Workstation Edition, MediaTek MT7927 WiFi 7 + 2×Ethernet, single NVMe, ZFS root, X11 + SDDM + XMonad dual-monitor.

Host name: `desktop`. Everything is declarative — one command from the laptop wipes and installs.

**Status: installed and verified.** The hardware table below is now confirmed from the
running box (2026-08), not assumed. WiFi, GPU P2P, and the container GPU path are all
working; see the per-section notes.

## Hardware assumptions (verify on first boot)

The machine is installed; the values below are **confirmed from the running box**. Several
tuning numbers depend on them, so they are still worth re-checking after any hardware
change. `survey-hardware` on the ISO reproduces every row except the two that need a
driver (VRAM, power limit). See
[Step 2](#answer-the-hardware-questions-before-you-wipe-anything).

| Item | Basis | Value | Where it matters |
|---|---|---|---|
| Board | **confirmed** | **ASUS ProArt X870E-CREATOR WIFI** (X870E, AM5), BIOS **1203** | Slot topology — see below |
| CPU | **confirmed** | **Ryzen 9 9950X**, 16C/32T, AM5 — `cpuCores = 16` is correct | PCIe lanes, build parallelism |
| RAM | **confirmed** | **96 GB** | `/dev/shm` = 48 GB, zram = 48 GB, ARC capped at 16 GiB |
| NVMe | **confirmed** | **Samsung 9100 PRO 2 TB in `M.2_1`** (`/dev/nvme0n1`) — `M.2_2` empty | Gen5 x4 CPU-direct; `M.2_2` empty is what keeps GPU 2 at x8 |
| PCIe topology | **confirmed** | **x8/x8, both from the CPU root complex** — P2P measured at **28.6 GB/s** (Gen5 x8 line rate) | whether GPU↔GPU P2P works at all |
| GPUs | **confirmed** | 2× RTX PRO 6000 Blackwell **Workstation Edition** `[10de:2bb1]`, ~96 GB each | `GPU_MEMORY_UTILIZATION=0.975` assumes 96 GB |
| GPU slots | **confirmed** | `PCIEX16(G5)_1` + `_2` → buses `01:00.0` / `03:00.0`, CPU root ports `00:01.1` / `00:01.3` | direct-attach P2P path |
| GPU variant | **confirmed** | **Workstation Edition, 600 W** | PSU, thermals, `gpuPowerLimitWatts = 450` |
| WiFi | **confirmed** | **MediaTek MT7927** (Filogic 380) `[14c3:7927]`, driver `mt7925e` — out-of-tree, needs `iommu=pt` | see [WiFi (MT7927)](#wifi-mt7927) |
| NICs | **confirmed** | `wlp10s0` (WiFi), `enp11s0` + `enp12s0` (2.5 Gb + 10 Gb) — flake `NICs` value is cosmetic (NetworkManager owns them) | non-blocking |

### What 96 GB of RAM means here

Worth stating plainly, because it is less than the 192 GB of VRAM across the two cards:

- **`/dev/shm` is 48 GB** (`boot.devShmSize` defaults to 50%). Under `--ipc=host` that is
  the hard ceiling on `KV_OFFLOADING_SIZE` — comfortably above the 16 GiB example retained by r33 and
  r24's offload gate of 5.5, but not a place to be careless.
- **The 155 GiB checkpoint cannot be cached in RAM.** It does not fit, and it is read once
  per server start. That is precisely why the ARC is capped at 16 GiB rather than left at
  the OpenZFS default of half of RAM — 48 GB of ARC here would be evicting live pages to
  cache a file nobody reads twice.
- **The 2 TB pool is comfortable**: ~155 GiB checkpoint + 512 GiB `native-l2` quota + `/nix`
  and `/home` leaves well over half the drive free.

### The one that could invalidate the DS4 setup: PCIe topology

Everything in the DS4 sections rests on GPU↔GPU PCIe P2P working. That is a property of
how the two cards attach to the CPU, and "AMD Ryzen" is exactly the ambiguous case.

Upstream's `iommu=off` guidance traces to a [Level1Techs
thread](https://forum.level1techs.com/t/dual-rtx-pro-6000-blackwell-max-q-how-to-make-p2p-nccl-work/242403)
whose working configuration is **ASUS WRX90E-SAGE SE + Threadripper PRO, both cards at
Gen5 x16** — a HEDT platform with 128 CPU lanes. A consumer AM5 CPU exposes 24 usable
PCIe 5.0 lanes total. That gives two realistic dual-GPU layouts:

- **x8/x8, both from the CPU root complex** (needs board bifurcation support) — P2P works,
  this is the topology upstream's direct-attach `ForceP2P` fix targets.
- **x16 + x4 from the chipset** — the second GPU sits behind the Promontory link, on a
  different branch. P2P between GPUs on different root complexes is the documented
  failure case: it degrades or does not work, and no amount of `ForceP2P` fixes wiring.

#### On this board, the good layout is available — and easy to lose

Per [ASUS's spec for the ProArt X870E-CREATOR WIFI](https://www.asus.com/us/motherboards-components/motherboards/proart/proart-x870e-creator-wifi/techspec/),
with a Ryzen 9000/7000 CPU:

| Slot | Attached to | Width |
|---|---|---|
| `PCIEX16(G5)_1` | **CPU** | x16, or x8 when slot 2 is populated |
| `PCIEX16(G5)_2` | **CPU** | x8 — **or x4, see below** |
| `PCIEX16_3` | chipset | PCIe 4.0 x4 — **never put a GPU here** |
| `M.2_1` | **CPU** | PCIe 5.0 x4 — no sharing |
| `M.2_2` | **CPU** | PCIe 5.0 x4 — **shares bandwidth with `PCIEX16(G5)_2`** |
| `M.2_3`, `M.2_4` | chipset | PCIe 4.0 x4 — no effect on the GPU slots |

The two full-length Gen5 slots are both CPU-attached and support `x16 / x8+x8 /
x8+x4+x4`. So the topology this whole document depends on is genuinely available — this
board is one of the few consumer AM5 boards where it is.

**The trap is `M.2_2`.** It is fed from the same CPU lanes as the second GPU slot.
Populate it and the board drops into the `x8/x4/x4` split: GPU 1 at x8, **GPU 2 at x4**,
M.2_2 at x4. That is precisely the "one GPU reports x4" hardware failure this section
warns about — except self-inflicted, by putting the boot drive in the wrong hole.

So the build must be:

- Both GPUs in **`PCIEX16(G5)_1` and `PCIEX16(G5)_2`**
- Boot NVMe in **`M.2_1`** — CPU-direct Gen5 x4, which is also the fastest slot for
  streaming a 155 GiB checkpoint
- **`M.2_2` left empty.** If you need more NVMe, use `M.2_3`/`M.2_4` (chipset) — they cost
  nothing from the GPU slots

#### You cannot tell which slot a card is in by looking at it

Slot silkscreen is usually hidden under the cards on a two-GPU build, and the bottom
full-length slot (`PCIEX16_3`, chipset x4) looks identical to the two good ones. Do not
guess — `survey-hardware` answers it exactly, in one line per card:

```
00:01.1/01:00.0 VGA compatible controller: NVIDIA ...   <- port path
00:01.3/03:00.0 VGA compatible controller: NVIDIA ...
                LnkSta: Speed 32GT/s, Width x8          <- link width (under load)
```

> On this box the confirmed paths are `00:01.1/01:00.0` and `00:01.3/03:00.0` — both
> CPU root ports, both x8. Note the link idles at `Speed 2.5GT/s (downgraded)`: that is
> NVIDIA's idle downclock, and it ramps to Gen5 (32GT/s) under load. The 28.6 GB/s P2P
> measurement is the proof it reaches full speed — don't read the idle `LnkSta` as a fault.

Read it like this:

| What you see | Verdict |
|---|---|
| Both paths start `00:01.1/` or `00:01.3/` (CPU root ports), both `Width x8` | **Correct.** x8/x8 from the CPU — proceed |
| Both `Width x16` | Only one card is present, or one is not being detected |
| One card `Width x4` | It is in `PCIEX16_3`, or something is populating `M.2_2` |
| Paths run through *different* bridges, one via the chipset | The second card is chipset-attached — **stop**, move it |

The width matters as much as the path: a card in the right slot still reports x4 if
`M.2_2` is stealing its lanes.

Check the physical build before installing, and confirm with `survey-hardware` after.

Check before trusting any benchmark:

```bash
nvidia-smi --query-gpu=index,name,pcie.link.gen.max,pcie.link.width.max --format=csv
nvidia-smi topo -m                  # both GPUs should sit on the same branch
lspci -PP -d 10de:                  # shows the full port path per GPU
```

If one GPU reports `x4`, or its `lspci -PP` path runs through a different bridge than the
other, the b12x PCIe allreduce premise does not hold on this board — that is a hardware
conclusion, not something to tune around.

That thread also notes "ACS is the only thing in the BIOS I flat out disabled" on a
direct-attach board. Upstream's own docs call ACS a switch-topology concern
(see [Not applicable to us](#not-applicable-to-us)); if your BIOS exposes an ACS toggle
and P2P misbehaves, it is worth trying despite that.

### Everything else worth capturing

`survey-hardware` on the installer stick runs all of these except the `nvidia-smi` pair,
which need the installed driver:

```bash
free -g                                        # RAM — drives /dev/shm, zram, ARC, KV offload
lscpu | grep -E "Model name|^CPU\(s\)"         # confirm cpuCores = 16
ip -o link show                                # confirm the NIC names
lsblk -d -o NAME,SIZE,MODEL                    # confirm /dev/nvme0n1

# After install only:
nvidia-smi -q -d POWER | grep -i "power limit" # 600W Workstation vs 300W Max-Q
nvidia-smi --query-gpu=memory.total --format=csv
```

RAM is the one to write down. Three settings are sized off it and they compete:

- `boot.devShmSize` (default `"50%"`) — under `--ipc=host` this *is* the container's
  `/dev/shm`, which is where the L1 KV offload region lives. 64 GB of RAM means a 32 GB
  shm ceiling: enough for serving, not for `KV_OFFLOADING_SIZE=48.5`.
- `zramSwap.memoryPercent = 50` — a ceiling on compressed swap, only consumed if the box
  actually swaps.
- `zfs.zfs_arc_max` — capped at 16 GiB here rather than the OpenZFS default of half of
  RAM. See [ZFS ARC](#zfs-arc-vs-the-kv-offload-region).

Disk size matters too, and is equally unrecorded: the checkpoint is ~155 GiB, the JIT
cache grows to several GiB, and `models/native-l2` is quota'd at 512 GiB. On a 1 TB drive
that is most of the pool.

Two 600W Workstation Edition cards draw 1200W of GPU alone, each on its own 16-pin
connector, and are 12" dual-fan coolers that sit poorly adjacent in a consumer ATX case.
The 300W Max-Q blower variant is the one designed for two-up. Which one is in the box
changes PSU sizing, case airflow, and sustained clocks — worth recording here.

## What's already in the flake

- `flake.nix`
  - `disko` input added (`github:nix-community/disko`)
  - Top-level `flake.nixosConfigurations` / `homeConfigurations` (so `nixos-anywhere` and `nixos-rebuild` find the host by name)
  - `desktop` host:
    - Roles: `core ssh wifi efi bluetooth dual-desktop-plasma nvidia-graphics`
      (`ssh` is required for headless management — see below)
    - Desktop env: `dual-desktop-plasma` role is **X11 + SDDM + XMonad** despite the name
      (`defaultSession = "none+xmonad"`), not KDE Plasma. Dual-monitor via xrandr in
      `services.xserver.displayManager.setupCommands`
    - Kernel: `pkgs.linuxPackages` (6.18+, ZFS-compatible, supports Blackwell)
    - User `peterstorm` in `wheel`, `networkmanager`, `docker`, `video`, `render`;
      authorized SSH keys from `authorized_keys.txt`
    - `cpuCores = 16`
- SSH: `roles/ssh` — publickey-only, hardened ciphers, no password auth. Post-install
  remote access requires your key in `authorized_keys.txt` (already wired for `desktop`).
- `machines/installer/` — the custom installer ISO, exposed as `.#installer-iso` and
  `.#installer-iso-offline`. See [Step 1](#step-1--build-the-installer-stick).
- `machines/desktop/disks.nix` — declarative disko layout
  - 1 GiB EFI (vfat) at `/boot`
  - Rest as ZFS pool `rpool` (ashift=12, zstd, atime=off, xattr=sa, acltype=posixacl)
  - Datasets: `root` → `/`, `nix` → `/nix`, `home` → `/home`, `docker` → `/var/lib/docker`
  - `models` → `/models` (recordsize=1M, compression=off — pre-compressed weights)
  - `models/vllm-cache` → `/models/vllm-cache` (recordsize=128K, **zstd**) — the JIT cache
    is compilable text and objects, the opposite of what the parent is tuned for
  - `models/native-l2` → `/models/native-l2` (recordsize=1M, compression=off,
    **quota=512G**) — the filesystem L2 KV tier introduced in r31 and retained by r33. The
    quota is the point: `NATIVE_L2_GB`
    is a promise the runtime makes about a directory, with nothing else stopping it from
    filling the pool underneath the checkpoint. Raise both together or neither.
- `machines/desktop/default.nix`
  - Imports disko + `disks.nix`
  - `boot.supportedFilesystems = [ "zfs" ]`
  - `networking.hostId = "8a3f2c19"`
  - **MediaTek MT7927 WiFi 7 + Bluetooth** — out-of-tree `mt76`/bluetooth modules and
    ASUS-extracted firmware from `cmspam/mt7927-nixos`, wired in with a corrected module
    layout (`updates/` not `extra/`). Requires `iommu=pt` (not `iommu=off`). See
    [WiFi (MT7927)](#wifi-mt7927).
  - `boot.kernelParams = [ "iommu=pt" "amd_iommu=on" ... ]` — P2P for the GPUs **and**
    working WiFi. See [Host prep](#host-prep-already-baked-into-the-flake).
  - `zramSwap` enabled (50% RAM, zstd) — no on-disk swap
  - `zfs.zfs_arc_max=16 GiB` — see [ZFS ARC](#zfs-arc-vs-the-kv-offload-region)
  - `virtualisation.docker.storageDriver = "zfs"` — see
    [Docker on ZFS](#docker-on-zfs-is-not-optional-here)
  - `powerManagement.cpuFreqGovernor = "performance"`
  - `gpuPowerLimitWatts` (currently `null`) — see [Power limits](#power-limits)
  - Auto-scrub + TRIM
  - AMD microcode
  - `specialisation.headless` — a second systemd-boot entry that boots to a console
    instead of SDDM/XMonad, so the GPUs start empty for inference. See
    [Going headless](#going-headless-to-free-gpu-memory). You can also flip live with
    `sudo systemctl isolate multi-user.target` / `graphical.target` — no reboot needed.
- **Home-manager is applied standalone**, like the laptops — it is *not* folded into the
  system closure. `homeManagerConfigurations.desktop` (in `flake.nix`) is the `peterstorm`
  user with a subset of roles (`core-apps window-manager/xmonad dunst`; the homelab/sops/
  obsidian roles are omitted because they need an age key). Apply with
  `./hm-apply.sh desktop`. (It used to be a NixOS module here purely so the offline USB
  install produced a driveable user with no network on first boot.)
- `roles/nvidia-graphics/default.nix` — rewritten for Blackwell
  - `hardware.nvidia.open = true` (required — Blackwell only supports the open kernel module)
  - `production` driver channel
  - `nvidiaPersistenced = true` (stable CUDA workloads)
  - `powerManagement.enable = false` (workstation, always on)
  - `hardware.nvidia-container-toolkit.enable = true` (Docker GPU passthrough)
  - `nvtopPackages.nvidia` in system packages
  - **GPU passthrough is CDI-based**, so `--device=nvidia.com/gpu=all` (or `=0` / `=1`;
    `device-name-strategy = "index"`) is the canonical form. The nixpkgs module only
    registers a Docker `nvidia` *runtime* under the deprecated
    `virtualisation.docker.enableNvidia`; with `hardware.nvidia-container-toolkit.enable`
    you get `features.cdi = true` and nothing else.
  - `systemd.services.docker.path` — the fix that also makes `--gpus all` work.
    Since moby 29.2 dockerd translates `--gpus` into a CDI request, but only if it
    can find `nvidia-cdi-hook` on its own PATH at daemon startup; NixOS gives dockerd
    a minimal unit PATH, so without this the lookup fails and `--gpus` dies with
    `could not select device driver "" with capabilities: [[gpu]]`. Upstream launch
    scripts use `--gpus all`, so this keeps them runnable verbatim.

## Tunables before you run

Read these once before `nixos-anywhere` — they're the only places hardware assumptions leak in.

| File | Setting | Current | When to change |
|---|---|---|---|
| `machines/desktop/disks.nix` | `diskDevice` | `/dev/nvme0n1` | If target NVMe isn't the first slot, or prefer `/dev/disk/by-id/nvme-...` |
| `flake.nix` (desktop) | `NICs` | `[ "wlp5s0" "enp6s0" ]` | Cosmetic — real interfaces are `wlp10s0`/`enp11s0`/`enp12s0`, but NetworkManager owns them, so this value is not load-bearing. Leave it or set `[ ]`; do **not** point it at the WiFi interface or networkd will fight NM for the DHCP lease |
| `machines/desktop/default.nix` | `networking.hostId` | `"8a3f2c19"` | Only if it collides with an existing host |
| `flake.nix` (desktop) | `cpuCores` | `16` | Set to actual core count for build parallelism |
| `roles/dual-desktop-plasma/default.nix` | xrandr `setupCommands` | **confirmed** `DP-4` (2560×1440) **rotated right / portrait** at 0,0 (left), `DP-6` (3840×1600 ultrawide) primary to its right at `1440x750` | Output names are per-GPU/cable — re-check with `xrandr --query` if you move a cable or swap a monitor |
| `authorized_keys.txt` | your pubkey | 4 keys | Must contain the key you SSH from. It is baked into **both** the installer ISO and the installed system, so a missing key locks you out of the install itself, not just the finished machine |
| `machines/desktop/disks.nix` | `models/native-l2` `quota` | `512G` | Raise together with `NATIVE_L2_GB`, never separately. Also check it fits the actual disk |
| `machines/desktop/default.nix` | `gpuPowerLimitWatts` | `null` | Set once `nvidia-smi -q -d POWER` tells you the card's range — see [Power limits](#power-limits) |

## Prerequisites (one-time, on your laptop)

- Nix with flakes: `experimental-features = nix-command flakes` in `~/.config/nix/nix.conf` (already set in dotfiles)
- Your public key in `authorized_keys.txt`, committed — the installer ISO is built from it
- Enough disk for the ISO build: ~2 GB for `.#installer-iso`, ~25 GB of scratch for
  `.#installer-iso-offline`

## Step 1 — Build the installer stick

The stock minimal ISO works, but it makes the one machine that has no monitor need a
monitor: you have to read an IP off the screen and type `passwd` before anything remote
can happen. This flake builds its own installer instead (`machines/installer`), in two
sizes:

| Package | Rough size | Use it when |
|---|---|---|
| `.#installer-iso` | 1.5 GB | Normal case — the laptop builds the closure and pushes it over SSH |
| `.#installer-iso-offline` | 4.4 GB | No laptop, no network, or you would rather not push the closure over WiFi |

The offline image is a strict superset: it does everything the thin one does *and* can
install locally, so if you are writing only one stick, write that one.

```bash
cd ~/.dotfiles
nix build .#installer-iso            # or .#installer-iso-offline
sudo dd if=result/iso/*.iso of=/dev/sdX bs=4M status=progress oflag=sync
sync
```

Replace `/dev/sdX` with the actual USB device. Double-check with `lsblk` before running.

What is baked in, and why each one removes a step:

| Baked in | Removes |
|---|---|
| Your keys from `authorized_keys.txt` in `root` **and** `nixos` | `passwd` at the console, and `--env-password` on the laptop |
| mDNS (`avahi`) publishing `installer.local` | Reading an IP off a monitor |
| ZFS in the running kernel | disko failing to create `rpool` — the userland `zfs` that nixos-anywhere uploads is useless without a matching kernel module |
| `VARIANT_ID=installer` in `/etc/os-release` | The kexec phase entirely. nixos-anywhere [detects an installer and skips it](https://nix-community.github.io/nixos-anywhere/howtos/no-os.html), so it never downloads or boots its own image |
| `nouveau` blacklisted | A black console on Blackwell, on the one boot that might want a screen |
| `survey-hardware` | Guessing at the table in [Hardware assumptions](#hardware-assumptions-verify-on-first-boot) |
| NetworkManager + `nmtui` | Being stuck if only WiFi is available |
| `install-desktop` (offline image only) | The laptop, and the network |

The offline image additionally carries the entire `desktop` system closure and its disko
script in the ISO's own Nix store (`isoImage.storeContents`), which is why it can install
with the network unplugged. The closure squashes down well — 4.4 GB, not the ~12 GB the
uncompressed closure would suggest.

> Building the offline image builds the full desktop closure — NVIDIA driver, kernel, X,
> the lot — and then squashfs-compresses it. Budget an hour the first time. The squashfs
> level is dropped from the nixpkgs default of `zstd -19` to `-6` precisely because of
> this; at `-19` it is most of an afternoon for a stick you write once.

## Step 2 — Boot the new desktop from the stick

- BIOS: UEFI mode, Secure Boot **off**, boot from USB.
- BIOS (for multi-GPU P2P — see the DS4 section below): **Above 4G Decoding = ON**,
  **Resizable BAR = ON**.

That is the whole console interaction. sshd is already up with your keys, so from the
laptop:

```bash
ssh root@installer.local
```

If mDNS does not resolve (some networks block it), find the IP from the router or plug in
a monitor once — the login banner explains the rest.

### Answer the hardware questions before you wipe anything

```bash
ssh root@installer.local survey-hardware
```

That prints the board, CPU, RAM, NVMe devices, NIC names, and — the one that matters —
the PCIe port path and link width of each GPU. Fill the
[Hardware assumptions](#hardware-assumptions-verify-on-first-boot) table in from its
output now. If it shows the two cards on different bridges, or one at `x4`, stop and read
[the PCIe topology section](#the-one-that-could-invalidate-the-ds4-setup-pcie-topology)
before installing: that is a hardware conclusion about whether this box can run the DS4
stack at all, and it is much cheaper to learn before disko wipes the disk than after.

`nvidia-smi` is not on the installer (no driver), so VRAM and power-limit range still wait
for [Step 5](#step-5--verify).

## Step 3 — Install

### From the laptop (`.#installer-iso`)

```bash
cd ~/.dotfiles

# Sanity check — should print "desktop"
nix eval .#nixosConfigurations.desktop.config.networking.hostName

# The install — this wipes /dev/nvme0n1 on the target
nix run github:nix-community/nixos-anywhere -- \
  --flake .#desktop \
  --target-host root@installer.local
```

What happens:
1. SSH into the installer as `root` (key already trusted, no password step)
2. **No kexec** — it sees `VARIANT_ID=installer` and installs in place
3. Partition + create the ZFS pool per `machines/desktop/disks.nix`
4. Build the closure on your laptop and copy it over
5. Install bootloader + system
6. Reboot

Expect 15–30 minutes on the first run — mostly NVIDIA driver + kernel build. Cached on
repeat.

### From the stick alone (`.#installer-iso-offline`)

```bash
ssh root@installer.local     # or just use the console
install-desktop
```

It prompts for confirmation, runs the same disko script, then `nixos-install --system`
against the closure already in the ISO's store. Nothing is fetched or built. This is also
the recovery path if the laptop is not around.

## Step 4 — Post-install setup

Once the machine reboots into the installed system, the `ssh` role's sshd is running
(publickey-only) and accepts your key from `authorized_keys.txt` for `peterstorm`.

> **Password:** `users.mutableUsers = false`, so runtime `passwd` does **not** persist —
> it reverts on the next `system-apply.sh` run. The console/SDDM password is the
> declarative `initialPassword` (`hunter2`, from `lib/user.nix`). To set a real one,
> add a `hashedPasswordFile` (sops) to the user rather than running `passwd`. For
> headless use you can ignore it and stay on key-based SSH.

Copy your dotfiles and age key. **`scp` does not work** — the `ssh` role sets
`allowSFTP = false`, so use `git clone` for the repo and a piped `cat`/`--extra-files`
for the key. Also note **`desktop.local` mDNS does not resolve over some WiFi APs**
(IPv4 mDNS multicast is dropped between wireless clients); use the IP, or the `ssh desktop`
alias baked into the laptop's home-manager (`roles/home-manager/core-apps`).

```bash
# On the desktop: clone the repo (scp/sftp is disabled on this host)
ssh peterstorm@<desktop-ip>        # or: ssh desktop  (laptop HM alias -> 192.168.0.80)
git clone https://github.com/peterstorm/.dotfiles ~/.dotfiles

# Seed the sops age key without sftp (pipe it in over ssh)
ssh peterstorm@<desktop-ip> 'mkdir -p ~/.config/sops/age && cat > ~/.config/sops/age/keys.txt && chmod 600 ~/.config/sops/age/keys.txt' < ~/.config/sops/age/keys.txt
```

Or fold the key into the install itself — `nixos-anywhere --extra-files` copies a directory
tree into the new root before first boot, so the machine comes up already holding it:

```bash
mkdir -p /tmp/seed/home/peterstorm/.config/sops/age
cp ~/.config/sops/age/keys.txt /tmp/seed/home/peterstorm/.config/sops/age/
nix run github:nix-community/nixos-anywhere -- \
  --flake .#desktop \
  --target-host root@installer.local \
  --extra-files /tmp/seed \
  --chown /home/peterstorm/.config 1000:100
```

Apply home-manager (standalone — note the `desktop` config name, a subset of the laptop's):

```bash
ssh desktop                        # or peterstorm@<desktop-ip>
cd ~/.dotfiles && ./hm-apply.sh desktop
```

## Step 5 — Verify

Run the [hardware assumptions](#hardware-assumptions-verify-on-first-boot) checks first —
this is the moment the PCIe topology and RAM questions get answered. Then:

```bash
nvidia-smi                             # both RTX 6000 Pro cards listed, CUDA Version >= 13.2
nvtop                                  # live view
cat /proc/driver/nvidia/params | grep RegistryDwords   # ForceP2P=0x11;... took effect
cat /proc/cmdline | tr ' ' '\n' | grep iommu           # iommu=pt amd_iommu=on (NOT iommu=off)
ip -o link show | grep -i wl           # wlp10s0 present + UP (MT7927 WiFi working)
zpool status                           # rpool ONLINE, all datasets mounted
zfs list                               # root/nix/home/docker/models + vllm-cache + native-l2

docker info | grep -i "storage driver" # must say zfs, not vfs
arc_summary | head -20                 # ARC target should cap at 16 GiB, not half of RAM
nvidia-smi topo -p2p rw                # GPU0<->GPU1 should read OK (P2P enabled)

# Container GPU passthrough — both forms should work (see the nvidia-graphics notes)
docker run --rm --device=nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
docker run --rm --gpus all              nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

If `docker info` reports **`vfs`**, dockerd could not initialize the zfs driver and fell
back to the slowest one there is — every layer becomes a full directory copy, which on a
multi-gigabyte CUDA image is brutal. Check `journalctl -u docker` for a `zfs` lookup
failure and see [Docker on ZFS](#docker-on-zfs-is-not-optional-here).

If `--device=` works but `--gpus all` reports `could not select device driver ""
with capabilities: [[gpu]]`, dockerd could not find `nvidia-cdi-hook` on its PATH —
check `systemctl show -p Environment docker.service` for the toolkit's `-tools` store
path, and restart dockerd after any change (the lookup happens once, at startup).

If *both* forms fail with `unresolvable CDI devices nvidia.com/gpu=all`, the CDI
generator raced the driver at boot — a known nixpkgs weakness (the module's own
comment calls its `udevadm settle` guard "terribly broken"). Regenerate:

```bash
sudo systemctl restart nvidia-container-toolkit-cdi-generator
ls /var/run/cdi/          # nvidia.yaml should exist
```

## Re-running

**`nixos-anywhere` is repeatable, not idempotent** — every run re-partitions and wipes the
disk through disko. It is the install command, not the update command. To iterate on the
config after install, use the normal flow:

```bash
ssh desktop                # laptop HM alias -> 192.168.0.80 (or peterstorm@<ip>)
cd ~/.dotfiles
./system-apply.sh          # system: the script already hardcodes `switch`; a second one errors
./hm-apply.sh desktop      # home-manager, standalone (separate step now)
```

To wipe and reinstall from scratch (destructive!), boot the USB again and re-run `nixos-anywhere`.

## Host tuning that is not about the GPUs

The P2P plumbing gets all the attention because it is the exotic part. These three are
duller and at least as load-bearing — the first is a latent failure, the second is
competing for the same RAM the KV cache wants, and the third is 1200 W of GPU in a
consumer case.

### Docker on ZFS is not optional here

`/var/lib/docker` is a ZFS dataset, and dockerd's storage-driver auto-detection cannot
land on `overlay2` there — moby's overlay2 initializer refuses a ZFS backing filesystem
outright, so it falls through to its own `zfs` graphdriver. That driver does not talk to
ZFS through a library; it shells out to the `zfs` binary.

And the NixOS docker module only puts `boot.zfs.package` on dockerd's PATH when
`storageDriver` is **explicitly** `"zfs"`:

```nix
path = [ pkgs.kmod ]
  ++ optional (cfg.storageDriver == "zfs") config.boot.zfs.package
  ++ cfg.extraPackages;
```

Auto-detection picking `zfs` does not satisfy that condition — it is a runtime decision,
the PATH is an eval-time one. So leaving the option unset means dockerd selects a driver
it cannot execute, on the machine whose entire purpose is running a 155 GiB container.
`machines/desktop/default.nix` sets it explicitly.

This is the same shape of bug as the `nvidia-cdi-hook` PATH problem in
`roles/nvidia-graphics`: NixOS gives dockerd a minimal unit PATH, and every helper binary
it expects to find has to be put there deliberately.

### ZFS ARC vs the KV offload region

OpenZFS on Linux defaults `zfs_arc_max` to half of RAM. That default is wrong for this
box in both directions:

- The 155 GiB checkpoint is read **once per server start**, sequentially, off a dataset
  with `recordsize=1M` and compression off. Caching it evicts pages that are actually
  reused to hold data nobody reads twice.
- The RAM the ARC takes is the RAM `/dev/shm` needs. Under `--ipc=host` the L1 KV offload
  region is an mmap in the host's `/dev/shm`, sized by `boot.devShmSize` — and an ARC
  sitting at half of RAM is competing directly with it.

`boot.kernelParams` caps it at 16 GiB (`zfs.zfs_arc_max=17179869184`), which is ample for
`/nix` and metadata. Verify with `arc_summary`. Raise it only if you find the ARC actually
thrashing on something that is not the checkpoint.

### Power limits

Upstream's [power-limit sweep](https://github.com/local-inference-lab/rtx6kpro/blob/master/hardware/blackwell-power-limit-sweep.md)
measured all three RTX PRO 6000 SKUs. The relevant findings for a two-up desktop:

- The three SKUs are the same silicon with different memory clocks, power states, and
  V/F curves in firmware — WS 13.4 GHz, Server 12.5 GHz, Max-Q 15.9 GHz memory.
- The 600 W Workstation card holds ~300–305 Gflop/s/W essentially flat from 200 W to
  350 W, and only reaches its peak 165k Gflop/s at the full 600 W.
- The Server SKU is dramatically more efficient at moderate power — 414 Gflop/s/W at
  300 W, a 38% advantage over WS, narrowing to 11% by 500 W.

Two 600 W cards is 1200 W of GPU alone, in a case that was not designed for it. Capping
each around 400–450 W gives up a few percent of throughput and buys back most of the
thermals and noise — and on a shared-airflow build, less throttling can leave *sustained*
clocks higher than the uncapped pair.

`machines/desktop/default.nix` has a `gpuPowerLimitWatts` binding that generates a
`nvidia-power-limit` oneshot unit when set. It is `null` until the SKU is known, because
`nvidia-smi -pl` exits non-zero for a value outside the card's supported range and the
600 W and 300 W cards do not share one:

```bash
nvidia-smi -q -d POWER | grep -iE "power limit"   # read the min/max/default
```

Then set the number and `./system-apply.sh`. `nvidiaPersistenced = true` is what keeps the
cap from being lost when the last client detaches.

## WiFi (MT7927)

The board's wireless is a **MediaTek MT7927 / MT6639 (Filogic 380)**, PCI `14c3:7927`
(Foxconn subsystem `105b:e124`). Kernel 6.18.41 does **not** claim it — mainline ships no
such modalias, and `linux-firmware` has `mediatek/mt7925` but nothing for MT6639. Both the
driver and the firmware therefore come out-of-tree from
[`cmspam/mt7927-nixos`](https://github.com/cmspam/mt7927-nixos) (which builds patched
`mt76` + bluetooth modules and extracts firmware from ASUS's Windows driver, tracking
[`jetm/mediatek-mt7927-dkms`](https://github.com/jetm/mediatek-mt7927-dkms)).

### How it's wired (`machines/desktop/default.nix`)

We take the flake's *packages* but re-do its install layout, because the upstream default
does not work on NixOS:

- **Modules go in `updates/`, not `extra/`.** `depmod` ranks `updates/` above `kernel/`
  but does **not** rank `extra/` above it, so the flake's `extra/` layout loses every name
  collision to the in-tree `mt76` modules — `modules.alias` ends up with only the in-tree
  `0717/7925` aliases (no `7927`) and the card is never claimed. After the fix,
  `mt7925e` carries the `14c3:7927` alias and resolves to `updates/`.
- **BT RAM code is installed to `mediatek/mt7927/` as well as `mediatek/mt6639/`** — the
  patched `btmtk` requests it from the former.
- An **ASPM udev rule** (`ATTR{link/l1_aspm}="0"` for `14c3:7927`) is kept from upstream.

The `nixosModule` from the flake is deliberately **not** imported (it uses the broken
`extra/` layout); the derivations are re-wired by hand at the top of the machine file.

### The one thing that actually breaks it: `iommu=off`

This is the trap that cost the most time. The GPU P2P work originally set
`boot.kernelParams = [ "iommu=off" "amd_iommu=off" ]`. With the AMD IOMMU **fully off**,
the MT7927's firmware download (a DMA transfer) never completes — the MCU's replies don't
land, and dmesg shows:

```
mt7925e ...: Message 00000010 (seq N) timeout
mt7925e ...: Failed to get patch semaphore
mt7925e ...: hardware init failed
```

The card enumerates and the driver binds, but WiFi never comes up. The tell was that the
**same card worked under Ubuntu**, whose only relevant difference was leaving the IOMMU
on. The fix is `iommu=pt amd_iommu=on` (passthrough): the GPUs still get their untranslated
P2P path, but the IOMMU stays enabled so the WiFi card can DMA its firmware. Do **not**
revert to `iommu=off` for any P2P reason — use ACS-disabled in BIOS instead (and on this
board even that turned out unnecessary; see [Verify P2P](#verify-p2p-before-benchmarking)).

### Verify

```bash
lspci -nnk -d 14c3:7927                # 'Kernel driver in use: mt7925e'
modinfo mt7925e | grep filename        # path must contain 'updates/', not 'kernel/'
sudo dmesg | grep -iE 'mt7925|mt6639'  # no 'Failed to get patch semaphore' / 'firmware ... failed'
ip -o link show | grep -i wl           # wlp10s0 present
nmtui                                  # connect
```

If `dmesg` shows the patch-semaphore failure, check `cat /proc/cmdline` for a stray
`iommu=off` first — that is the cause 99% of the time here. A full **cold** power-cycle
(PSU off, not a warm reboot) also clears a wedged MCU state.

### Reaching the box by name

mDNS (`desktop.local`) is published by avahi (physical NICs only — `allowInterfaces` keeps
docker bridges out of it), and every host with the `wifi` role now resolves `.local`
(`nssmdns4`+`nssmdns6`). **Caveat:** some consumer APs drop IPv4 mDNS multicast between
wireless clients, so `desktop.local` may only resolve over IPv6 link-local or not at all
from another WiFi box. The reliable path is the **`ssh desktop` alias** in the laptop's
home-manager (`roles/home-manager/core-apps`, a static-IP entry like `homelab`).

## Running DS4 v8 (DeepSeek-V4-Flash on vLLM)

Guide: <https://github.com/local-inference-lab/rtx6kpro/blob/master/models/ds4dspark-v8.md>
Host prep reference: <https://github.com/local-inference-lab/rtx6kpro/blob/master/optimization/nccl-tuning.md>
and <https://github.com/local-inference-lab/rtx6kpro/blob/master/optimization/pcie-oneshot-allreduce.md>

Everything (CUDA 13.2.1, PyTorch 2.12, vLLM) ships **inside the pinned container**
(`voipmonitor/vllm:eldritch-enlightenment-v2226f26-b12x15cd38c-cu132-20260629`). The host
only provides driver + P2P plumbing. The guide's own launch example is `GPUS=0,1 TP=2` —
exactly our 2-card single-node case, so TP2 is a first-class supported mode.

For the image actually being run on this box, see
[Running DeepSeek-V4-Flash (Gilded Gnosis r33, K5)](#running-deepseek-v4-flash-gilded-gnosis-r33-k5)
below — same host prep, different container.

### Host prep (already baked into the flake)

- `machines/desktop/default.nix` sets `boot.kernelParams = [ "iommu=pt" "amd_iommu=on" ]`
  and the nvidia / nvidia_uvm modprobe overrides (`ForceP2P`, `EnableResizableBar`,
  `uvm_disable_hmm`). RTX 6000 Pro has no NVLink, so the vLLM b12x PCIe allreduce and
  `NCCL_P2P_LEVEL=SYS` depend on GPU↔GPU PCIe P2P working. On a direct-attach desktop
  board, `iommu=pt` gives the GPUs an untranslated P2P path (the equivalent of the
  ACS-override `setpci` dance PCIe-switch server boards need) **while keeping the IOMMU
  on for every other device** — which is required for the on-board MediaTek MT7927 WiFi
  to DMA-load its firmware. `iommu=off` breaks that WiFi card (see the WiFi section);
  `iommu=pt` does not, and still gives P2P. Needs `ACS = Disabled` in BIOS.
- `roles/nvidia-graphics/default.nix` uses the `production` driver with `open = true`
  (required for Blackwell). `production` currently resolves to **driver 595.84 on kernel
  6.18.41** — confirmed new enough for the container's CUDA 13.2. Still worth a glance:
  after first boot verify `nvidia-smi` shows CUDA Version ≥ 13.2.

The `NVreg_RegistryDwords` string in `machines/desktop/default.nix` is copied verbatim
from the upstream direct-attach P2P fix (`optimization/pcie-oneshot-allreduce.md`), and
`uvm_disable_hmm=1` is an explicit upstream requirement
(`optimization/nccl-tuning.md` — without it NCCL P2P locks up and NCCL hangs). Upstream
pairs it with `iommu=off amd_iommu=off`; we use `iommu=pt amd_iommu=on` instead (same
untranslated P2P path, but the IOMMU stays on so the MT7927 WiFi card still works — the
upstream notes record `amd_iommu=on iommu=pt` + ACS-disabled as an equivalent P2P config).

**Does that survive `open = true`?** Upstream runs the proprietary driver; Blackwell on
NixOS forces the open kernel module, so the keys were worth checking against
`NVIDIA/open-gpu-kernel-modules`:

| Key | Value | Status in the open module |
|---|---|---|
| `ForceP2P` | `0x11` | `nvrm_registry.h` — READ+WRITE enabled, atomics left disabled |
| `RMForceP2PType` | `1` | `nvrm_registry.h` — `PCIEP2P` |
| `RMPcieP2PType` | `2` | `nvrm_registry.h` — `AUTO` (BAR1 with mailbox fallback) |
| `EnableResizableBar` | `1` | `nv-reg.h` |
| `GrdmaPciTopoCheckOverride` | `1` | not in the public headers |

The first four are real, documented keys in the open source tree, so `open = true` does
not silently discard them. `GrdmaPciTopoCheckOverride` appears in neither header — the
driver passes unmatched pairs straight to the resource manager, so it is plausibly handled
there, but it cannot be confirmed from source. This is exactly why the verification step
below reads `/proc/driver/nvidia/params` instead of trusting the config.

### BIOS

Above 4G Decoding **ON** and Resizable BAR **ON** (see Step 2). `EnableResizableBar=1`
in modprobe is a no-op without ReBAR enabled in firmware.

Exact paths on the ProArt X870E-CREATOR WIFI (press `F7` for Advanced Mode first):

| Setting | Path | Value |
|---|---|---|
| CSM | `Boot` → `CSM (Compatibility Support Module)` → `Launch CSM` | **Disabled** |
| Above 4G Decoding | `Advanced` → `PCI Subsystem Settings` | **Enabled** |
| Re-Size BAR Support | `Advanced` → `PCI Subsystem Settings` | **Enabled** |
| Secure Boot | `Boot` → `Secure Boot` → `OS Type` | **Other OS** |
| Memory profile | `Ai Tweaker` → `Ai Overclock Tuner` | **EXPO** |

Order matters twice: **`Re-Size BAR Support` only appears once `Above 4G Decoding` is
Enabled**, and ReBAR additionally requires CSM disabled. Disable CSM first, then the other
two — otherwise you will look for a menu entry that is not being displayed and conclude the
board lacks it.

Leave IOMMU on `Auto`; `iommu=pt amd_iommu=on` in `boot.kernelParams` settles the
passthrough behaviour from the kernel side. Do **not** use `iommu=off` here: it kills the
on-board MT7927 WiFi (firmware DMA never completes — see [WiFi (MT7927)](#wifi-mt7927)).

**On ACS:** this board does **not** appear to expose an ACS toggle in BIOS (there is a
`PCIe ARI Support` entry — that is *not* ACS; leave it at its default). It turned out not
to matter: with `iommu=pt` alone, P2P measured at full Gen5 x8 bandwidth (28.6 GB/s). If a
future board *does* expose ACS and P2P underperforms, disabling it is the knob to try — but
do not go hunting for a setting that isn't there.

Bifurcation needs no configuration for this build: two cards in the two Gen5 slots
negotiate x8/x8 automatically. The bifurcation menu exists for splitting one slot across
a riser, which is not what we are doing. What *does* need attention is the physical build
— see [the M.2_2 trap](#on-this-board-the-good-layout-is-available--and-easy-to-lose).

### Reaching the server from the LAN

`machines/desktop/default.nix` opens TCP **8000** in the firewall, so the vLLM
OpenAI-compatible endpoint (`PORT=8000`, container runs `--network host`) is reachable at
`http://<desktop-ip>:8000/v1` from other LAN machines (e.g. `http://192.168.0.80:8000/v1`).
Use the IP, not `desktop:8000`, from arbitrary devices — `.local` mDNS is unreliable over
some WiFi APs (see [WiFi](#wifi-mt7927)); only hosts with an explicit alias/hosts entry
resolve the name. Change the port there if you launch the server on a different one.

That firewall entry only matters under `--network host`, which both the DS4 v8 helper and
the r33 profile use. If you swap in `-p 8000:8000`, Docker publishes through its own
iptables chain and the port is reachable whether or not it is in `allowedTCPPorts`.

### Model cache → /models

The checkpoint is ~155 GiB. Keep it on the dedicated `/models` ZFS dataset
(recordsize=1M, compression=off — tuned for pre-compressed weights). The JIT cache and the
native L2 tier get their own child datasets with their own tuning — see
[What's already in the flake](#whats-already-in-the-flake); do not put the JIT cache
directly on `/models`, where it inherits 1M records and no compression.

The rest of this subsection is about the **DS4 v8 helper script**, which is not what the
r33 command below uses — that one passes absolute `/models/...` paths and needs none of
these symlinks. Keep it for running the v8 guide verbatim; skip it otherwise.

`scripts/run-ds4-v8-server.sh` mounts two things, and neither path is what you'd guess:

- `-v /root/.cache/huggingface:/root/.cache/huggingface:ro` — **read-only**, so the
  checkpoint must be fully downloaded *before* launch, not fetched by the server.
- `-v "$CACHE:/cache:rw"` where `CACHE` defaults to `/root/.cache/vllm-ds4-v8/$NAME`
  (i.e. `/root/.cache/vllm-ds4-v8/ds4-v8`) — mounted at `/cache`, not at its host path.
  This holds compiled kernels and CUDA graphs; keep it persistent or every start
  recompiles.

Docker resolves host-side symlinks when it binds, so pointing these at `/models` works —
but `ln -sfn` drops the link *inside* an existing directory, so clear the targets first:

```bash
sudo mkdir -p /models/hf /models/vllm-ds4-v8
sudo rm -rf /root/.cache/huggingface /root/.cache/vllm-ds4-v8
sudo ln -sfn /models/hf /root/.cache/huggingface
sudo ln -sfn /models/vllm-ds4-v8 /root/.cache/vllm-ds4-v8
```

Simpler alternative: skip the symlinks and pass absolute `/models/...` paths via
`CACHE=` and the `MODEL_DIR`-style overrides, as the SM120 command below does.

### Verify P2P before benchmarking

Confirm P2P is actually enabled — otherwise the allreduce path silently falls back to
SysMem staging and runs ~15× slower than NCCL, and vLLM's auto-crossover quietly disables
the custom allreduce entirely.

**`nvidia-smi topo -m` does not answer this question.** On a direct-attach board it
reports `NODE` between the GPUs both before and after the fix — that is expected, not a
failure. Check the driver params instead:

```bash
cat /proc/driver/nvidia/params | grep RegistryDwords
# must show: ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;...

# Real measurement (upstream's crossover benchmark, or cuda-samples):
#   bench_crossover.py — custom AR should win up to ~512 KB (~16 us at 114 KB)
#   simpleP2P / p2pBandwidthLatencyTest
```

**Confirmed on this box (2026-08):** `nvidia-smi topo -p2p rw` reports `OK` for GPU0↔GPU1
read *and* write under `iommu=pt`, `cudaDeviceCanAccessPeer` is 1 both directions, and a
unidirectional `cudaMemcpyPeer` benchmark measured **28.6 GB/s** — line rate for **Gen5
x8** (Gen4 x8 would be ~16, host-staged fallback ~10–12). So P2P is genuinely enabled at
full bandwidth, and **ACS did not need disabling** on this board (see BIOS note below).

The `nvcr.io/nvidia/cuda-samples` image needs an NGC login; a self-contained alternative
that needs no auth is to compile a tiny `cudaMemcpyPeer` timer in the public
`nvidia/cuda:*-devel` image:

```bash
docker run --rm --gpus all --ipc=host -v /tmp:/tmp nvidia/cuda:12.4.1-devel-ubuntu22.04 \
  bash -lc 'cat > /tmp/p2p.cu <<EOF
#include <cstdio>
#include <cuda_runtime.h>
int main(){int n;cudaGetDeviceCount(&n);int c;cudaDeviceCanAccessPeer(&c,0,1);
printf("canAccessPeer=%d\n",c);size_t b=256UL<<20;void*a,*d;
cudaSetDevice(0);cudaMalloc(&a,b);cudaSetDevice(1);cudaMalloc(&d,b);
cudaSetDevice(0);cudaDeviceEnablePeerAccess(1,0);cudaSetDevice(1);cudaDeviceEnablePeerAccess(0,0);
cudaSetDevice(0);cudaEvent_t s,e;cudaEventCreate(&s);cudaEventCreate(&e);
for(int i=0;i<10;i++)cudaMemcpyPeer(d,1,a,0,b);cudaDeviceSynchronize();
cudaEventRecord(s);for(int i=0;i<100;i++)cudaMemcpyPeer(d,1,a,0,b);cudaEventRecord(e);cudaEventSynchronize(e);
float ms;cudaEventElapsedTime(&ms,s,e);printf("P2P 0->1: %.1f GB/s\n",(double)b*100/1e9/(ms/1000));}
EOF
nvcc -O3 -o /tmp/p2p /tmp/p2p.cu && /tmp/p2p'
```

> Note the GPU `LnkSta` idles at `2.5GT/s (downgraded)` — NVIDIA's idle downclock, not a
> fault. The 28.6 GB/s result is the proof the link ramps to Gen5 under load.

If `RegistryDwords` is empty, the modprobe config didn't take: reboot, or stop everything
holding the GPUs (`nvidia-persistenced`, containers, the display manager — see
[Going headless](#going-headless-to-free-gpu-memory)) and reload `nvidia_uvm` /
`nvidia_modeset` / `nvidia`.

### Not applicable to us

**`NCCL_GRAPH_FILE`** — the `/mnt/nccl_graph_opt.xml` fix lives in
`optimization/nccl-tuning.md`, not in the v8 guide, and it corrects NCCL's bandwidth
misdetection (192–256 GB/s read as 16 GB/s) **on AMD EPYC Turin**. This box is Ryzen, so
it does not apply. Note the v8 launch helper goes further and *unconditionally unsets*
`NCCL_GRAPH_FILE`, `NCCL_GRAPH_DUMP_FILE`, and `VLLM_B12X_MLA_EXTEND_MAX_CHUNKS` before
`vllm serve` — and warns never to set `NCCL_GRAPH_FILE=` to an empty string.

**ACS overrides** — the runtime `pcie_acs_override` / `setpci` dance is switch-topology
only (and `pcie_acs_override` needs a patched kernel anyway). Direct-attach boards use the
`ForceP2P` modprobe config instead, which is what we do.

One caveat on that: the Level1Techs thread upstream cites for `iommu=off` is a
direct-attach dual RTX PRO 6000 build, and its author reports "ACS is the only thing in
the BIOS I flat out disabled". We reach the same place a different way — `amd_iommu=on
iommu=pt` — because the on-board MediaTek MT7927 WiFi needs the IOMMU left on to DMA-load
its firmware, and `iommu=off` breaks it (`Message ... timeout` → `Failed to get patch
semaphore` → `hardware init failed`). In practice `iommu=pt` alone was enough: P2P measured
at full Gen5 x8 bandwidth (28.6 GB/s) **without** any ACS toggle — and this board doesn't
expose one anyway (`PCIe ARI Support` is a different feature). So `iommu=pt` keeps P2P
*and* WiFi working, and ACS-disabled is a fallback only if a future board needs it.

**`optimization/io-tuning.md`** — every number in it is about an **md RAID5 array**:
`stripe_cache_size`, `group_thread_cnt`, write-intent bitmaps, read-ahead, and switching
NVMe to the BFQ scheduler for cgroup fairness. This box is a single NVMe with ZFS and no
parity layer, so the bottleneck it diagnoses (one `md0_raid5` kernel thread at 95.8% of a
core, 645 ms write latency) cannot occur. Do not copy its `read_ahead_kb` or scheduler
settings across — the ARC cap in
[ZFS ARC](#zfs-arc-vs-the-kv-offload-region) is the equivalent knob here.

### One upstream caveat that *does* apply

`optimization/pcie-oneshot-allreduce.md` records that
**`PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` is incompatible with the PCIe oneshot
allreduce** — expandable allocator segments break the IPC memory-handle exchange the
kernel relies on. Do not set it in the container's environment.

r33 retains the native-L2 behavior introduced in r31: its helper *itself* disables
expandable segments, "because the shared host region requires stable registrations".
So if you enable native KV offload and something else in your environment
has turned expandable segments on, the two are fighting over the same allocator.

## Running DeepSeek-V4-Flash (Gilded Gnosis r33, K5)

Runbook: <https://github.com/local-inference-lab/rtx6kpro/blob/master/models/ds4dspark-v20-r33.md>

The official validated r33 release image, adapted for this box. It retains r31's vLLM,
FlashInfer, LMCache, compressed-MLA, graph, native-offload, and reasoning/tool contracts,
while updating B12X. Host preparation is unchanged: ForceP2P modprobe config,
`iommu=pt amd_iommu=on`, ReBAR, and Above 4G Decoding. The model revision is unchanged,
so an existing pinned 0731 download does not need to be replaced.

| Item | Value |
|---|---|
| Image | `voipmonitor/vllm:gilded-gnosis-v20-vllmfa13d33-b12x06db0f4-fi1ac6942-cu132-20260809-r33` |
| Registry digest | `sha256:fdde59fed7f9fc12f9fd5ef1b3b3ea8d5097bf10ebad54b348497102c3a83f82` |
| Model revision | `9e165c30e2704aec5d9d593cce3eebd58bbef1cb` |
| Runtime | CUDA 13.2.1, PyTorch 2.12.0+cu132, CUTLASS DSL 4.6.0, XGrammar 0.2.5 |
| Default profile | TP2/DCP1, B12X W4A8, fixed probabilistic K5, FP8 DS-MLA KV |
| Validation | [PR #20](https://github.com/local-inference-lab/blackwell-llm-docker/pull/20), [remote GPU receipt](https://github.com/local-inference-lab/blackwell-llm-docker/blob/main/validation/gilded-gnosis-v20-r33-remote-gpu.json) |

TP2/DCP1 being the *default* profile is worth noticing: the release's own baseline is our
exact two-card shape, not something we are adapting down to. The repository helper is the
preferred launch path; it creates a persistent machine-local API key and pins the image
digest:

```bash
bash scripts/run-ds4-v20-r33.sh
```

Its equivalent `docker run` contract is below. Put the key in a private env file rather
than a `-e VLLM_API_KEY=value` argument: command arguments are visible through `/proc`.

```bash
install -m 700 -d ~/.config/ds4-flash
printf 'VLLM_API_KEY=%s\n' '<API_KEY>' > ~/.config/ds4-flash/container.env
chmod 600 ~/.config/ds4-flash/container.env

docker run --init \
  --restart unless-stopped \
  --name ds4-0731-r33 \
  --gpus all \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file ~/.config/ds4-flash/container.env \
  -v /models/DeepSeek-V4-Flash-0731:/models/deepseek-ai/DeepSeek-V4-Flash-0731:ro \
  -v /models/vllm-cache/r33:/cache \
  -v /models/vllm-cache/r33/tmp:/container-tmp \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e SERVED_MODEL_NAME=deepseek-v4-flash \
  -e MODEL_PATH=/models/deepseek-ai/DeepSeek-V4-Flash-0731 \
  -e PORT=8000 \
  -e MODE=dspark -e DSPARK_DEPTH_MODE=fixed -e DSPARK_TOKENS=5 \
  -e BACKEND=b12x-a8 -e TP_SIZE=2 -e DCP_SIZE=1 \
  -e ALLREDUCE_MODE=auto \
  -e B12X_PCIE_TP2_REMOTE_PUSH=0 \
  -e B12X_PCIE_TP4_REMOTE_PUSH=0 \
  -e B12X_PCIE_TP8_OWNER_REDUCE=1 \
  -e MAX_NUM_SEQS=8 -e MAX_MODEL_LEN=1048576 -e MAX_NUM_BATCHED_TOKENS=4096 \
  -e GRAPH=auto \
  -e GPU_MEMORY_UTILIZATION=0.975 \
  -e LOAD_FORMAT=instanttensor -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e PYTHONHASHSEED=0 \
  -e KV_OFFLOADING_SIZE=0 \
  voipmonitor/vllm:gilded-gnosis-v20-vllmfa13d33-b12x06db0f4-fi1ac6942-cu132-20260809-r33@sha256:fdde59fed7f9fc12f9fd5ef1b3b3ea8d5097bf10ebad54b348497102c3a83f82 \
  /usr/local/bin/serve-ds4-flash.sh
```

```bash
curl -fsS http://127.0.0.1:8000/health
docker logs -f ds4-0731-r33
```

**Validated on this exact box (2026-08-09):**

- The registry resolved the pinned image to
  `voipmonitor/vllm@sha256:fdde59fed7f9fc12f9fd5ef1b3b3ea8d5097bf10ebad54b348497102c3a83f82`.
- The pinned model revision occupied 162 GiB on disk. InstantTensor loaded the target and
  draft weights in 25.78 s and 24.88 s; CUDA graph capture took 22 s. The complete cold
  r33 startup, including first-time JIT work, reached `Application startup complete` in
  about five minutes.
- `ALLREDUCE_MODE=auto` correctly selected `flashinfer-ipc` for TP2, dispatched larger
  shapes to PyNCCL, and retained B12X for sparse MLA, MoE, and linear kernels. Both
  remote-push experiments remained disabled.
- The initial conservative profile exposed 143,545 effective sequence-token capacity
  (8.07 GiB raw KV memory per worker) at `MAX_MODEL_LEN=131072`, `MAX_NUM_SEQS=16`, and
  `MAX_NUM_BATCHED_TOKENS=8192`. This was a configuration-dependent hybrid-cache metric,
  not a fixed bytes-per-token limit; the tuned profile below supersedes it.
- `/health` returned HTTP 200; the container remained running with zero restarts. An
  authenticated OpenAI-compatible chat request returned exactly `OK` with
  `finish_reason=stop` (88 prompt tokens, 28 completion tokens). A 16-token completion
  cap was too small because reasoning consumed it before visible content; use a realistic
  output allowance when probing a reasoning-enabled profile.
- During initialization both GPUs reached roughly 94.7 GiB used. Temperatures remained
  below 50°C and the card fans held at 30%; the audible spin-up was expected weight/JIT/
  graph activity, not a thermal fault.

### Eight-agent KV-capacity profile

The checkpoint declares `max_position_embeddings=1048576` (YaRN factor 16 over its
original 65,536-token envelope). This box therefore uses:

```text
MAX_MODEL_LEN=1048576
MAX_NUM_SEQS=8
MAX_NUM_BATCHED_TOKENS=4096
GPU_MEMORY_UTILIZATION=0.975
KV_OFFLOADING_SIZE=0
```

`MAX_MODEL_LEN` is the per-request prompt-plus-output ceiling; paged KV blocks are still
allocated dynamically, so eight agents do **not** reserve 1M tokens each. Lowering MNS
from 16 to 8 admits the desired eight active agents while reducing graph and activation
headroom; lowering MNBT from 8192 to 4096 chunks large prefills more finely and leaves
more VRAM for KV.

DeepSeek-V4 uses hybrid cache groups and a 128-token sliding window. In r33,
`get_kv_cache_capacity()` reports `max_concurrency * MAX_MODEL_LEN`, where concurrency is
computed from the maximum memory usage of those groups. Consequently the displayed token
capacity legitimately depends on `MAX_MODEL_LEN`; it is an effective logical sequence
capacity, not `raw bytes / constant bytes per token` as for a uniform full-attention
model.

With the profile above, startup measured:

| Metric | Result |
|---|---:|
| Raw KV memory per worker | 8.71 GiB |
| Effective KV capacity | 1,196,363 tokens |
| Full-1M-request concurrency | 1.14094x |
| GPU blocks | 8,678 |
| CUDA graph envelope | 48 rows |
| Native/CPU KV offload | Disabled |

An overlap pressure test submitted eight unique-prefix requests concurrently, each with
about 130,118 prompt tokens and a forced 16,000-token generation. All eight became active
at once; waiting fell to zero, peak KV usage reached 84.6%, preemptions remained zero,
and all eight requests returned HTTP 200. The run processed about 1.041M prompt tokens
plus 128k generated tokens. This validates eight ~130k coding-agent contexts sharing the
pool; it does not certify answer quality beyond the upstream ~200k caveat below.

The launch-time defaults remain overrideable, for example:

```bash
MAX_NUM_SEQS=4 MAX_MODEL_LEN=1048576 MAX_NUM_BATCHED_TOKENS=4096 \
  bash scripts/run-ds4-v20-r33.sh
```

Four agents get a larger dynamic share of the same pool; no separate cache partition is
created per agent.

Or run upstream's commit-pinned Compose directly and let the environment do the work.
The file is immutable at this URL, but its `image:` value is a tag rather than a digest;
the local `docker run` helper above additionally pins the verified registry digest:

```bash
curl -LO https://raw.githubusercontent.com/local-inference-lab/blackwell-llm-docker/426da51285d0666508003b03a75a442139fb7979/examples/docker-compose-ds4-v20-r33.yml
GPUS=0,1 TP_SIZE=2 DCP_SIZE=1 \
MODEL_ROOT=/models JIT_CACHE=/models/vllm-cache/r33 \
CONTAINER_TMP=/models/vllm-cache/r33/tmp \
NATIVE_L2_HOST_PATH=/models/native-l2 \
docker compose -f docker-compose-ds4-v20-r33.yml up -d
```

Note the Compose file's `environment:` block enumerates exactly which variables reach the
container, and `VLLM_API_KEY`, `SERVED_MODEL_NAME`, and `MODEL_PATH` are **not** among
them. If you go the Compose route on a `--network host` server, add them through an
override file — otherwise the endpoint is on the LAN with no key.

**Deviations from upstream's Compose file, and why:**

| Change | Reason |
|---|---|
| `--gpus all` | Matches the Compose file's own `gpus: all`. Works here because of `systemd.services.docker.path` in `roles/nvidia-graphics`; `--device=nvidia.com/gpu=all` is the equivalent needing no host-side help. |
| Explicit model mount + `MODEL_PATH` | Compose defaults to scanning `${MODEL_ROOT:-/root/models}`. Pointing straight at the checkpoint skips the HF cache mount entirely. |
| Caches under `/models/vllm-cache/r33` | Its own ZFS dataset (zstd, 128K records), rather than a relative `./cache` next to a git checkout. |
| Private `--env-file` for `VLLM_API_KEY` | Keeps the API key out of Docker's process arguments and `/proc`; the helper rewrites it mode 0600 on every launch. |
| `CUDA_DEVICE_ORDER=PCI_BUS_ID` | Makes `CUDA_VISIBLE_DEVICES=0,1` match `nvidia-smi` ordering instead of driver enumeration order. |
| `--restart unless-stopped`, no `--rm` | Matches Compose. The two flags are mutually exclusive in `docker run`; use `--rm` and drop the restart policy for throwaway benchmarking. |

**`--privileged` is gone, and that is an upstream change, not a local guess.** The r24
notes on this page flagged it as "upstream's choice, not a verified requirement", carried
since r16 with no stated rationale, and worth testing without. The r33 Compose file,
like r31 before it, does not have it, and
[issue #33](https://github.com/local-inference-lab/rtx6kpro/issues/33) records that even
native L2 — the feature with the most plausible claim on it, since it pins and shares
host memory — "was validated without privileged container access". Drop it.

Two things still worth knowing:

- **`--ipc=host` with no `--shm-size`.** The Compose file sets both, but `shm_size` is
  inert under host IPC — measured: `--ipc=host --shm-size=1g` yields the host's 7.7G
  `/dev/shm`, while `--shm-size=1g` alone yields exactly 1.0G. Under host IPC the
  governing number is the NixOS host's `boot.devShmSize` (default `"50%"` of RAM), which
  is also what the ARC cap is protecting. If you would rather have a private,
  RAM-independent arena, drop `--ipc=host` and use `--shm-size=32g` — but read
  [native KV offload](#native-l1l2-kv-offload-r33-retained) first.
- **`DRAFT_SAMPLE_METHOD=greedy` is dropped.** It was never part of the release profile —
  it was carried over from an older command on this page and is in no Compose file, so the
  helper's own default applies. Removing it makes this the release profile exactly.

`--network host` means the vLLM endpoint binds every interface, so the
`allowedTCPPorts = [ 8000 ]` entry in `machines/desktop/default.nix` is what makes
`http://desktop:8000/v1` reachable. `VLLM_API_KEY` is doing the access control — keep it
set. For a contained alternative, swap `--network host` for `-p 8000:8000`.

### CUDA graph sizing is automatic (`GRAPH=auto`)

The physical verifier-row requirement remains:

```text
MAX_NUM_SEQS * (1 + DSPARK_TOKENS)
```

For this box's `MAX_NUM_SEQS=8` at K5 that is `8 * (5 + 1) = 48`.
`GRAPH=auto` derives the cap, so the arithmetic only matters when checking logs. The
upstream r33 TP2/K5 validation captured through 96 rows at MNS16; our MNS8 profile
captured the required 48-row envelope. No device-heavy decode stage relied on eager
fallback.

What is captured as of r33:

| Stage | Execution |
|---|---|
| Target/verifier forward | FULL CUDA graph |
| DSpark proposal | FULL CUDA graph |
| DSpark context-KV compression/update | Dedicated FULL CUDA graph |
| Prefill | PIECEWISE CUDA graph |
| Host metadata/input preparation | Eager host path |
| Rejection sampling/output bookkeeping | Eager path |

The eager rows are the reason `powerManagement.cpuFreqGovernor = "performance"` is set on
this host: the decode path still has a variable host-side chain, and upstream is explicit
that capturing rejection sampling's small device kernel would not remove the host
bookkeeping.

### All-reduce backend selection (`ALLREDUCE_MODE`)

The reversible, logged policy introduced in r31 remains in r33:

| TP | Automatic backend | Diagnostic override |
|---|---|---|
| **TP2 (us)** | FlashInfer PCIe IPC | `ALLREDUCE_MODE=b12x` |
| TP4 | B12X | `ALLREDUCE_MODE=flashinfer-ipc` |
| TP8 | B12X owner reduction | `ALLREDUCE_MODE=flashinfer-ipc` |

B12X #133 adds opt-in TP2/TP4 remote-push paths. r33 deliberately leaves them disabled:
matched runs showed workload-dependent gains and losses rather than a consistent
end-to-end improvement. Test only one variable at a time with
`B12X_PCIE_TP2_REMOTE_PUSH=1`; the helper sets it to `0` by default.

The r33 fixed-K5 TP2 validation reported 180.6 tok/s at C1, 397.1 at C4, and 580.7 at C8,
with strict acceptance of 29.4% / 34.5% / 33.3%. Uncached 8k prefill reached 12,849 tok/s.
Those figures came from GPUs attached through CPU root ports, making the topology relevant
to this box, but acceptance is prompt-dependent and they are not a pure backend A/B.
Keep `auto` for the first validated run, then benchmark `b12x` separately for this
single-user coding workload.

### K7 is no longer discouraged — the r24 warning was wrong

This page previously said `DSPARK_TOKENS=7` was "actively discouraged" and carried an open
corruption defect. r31 corrected that status, and r33 retains it:

| Mode | Environment | Status |
|---|---|---|
| Fixed K5 | `DSPARK_DEPTH_MODE=fixed DSPARK_TOKENS=5` | Default; best proven mixed-workload choice |
| Fixed K7 | `DSPARK_DEPTH_MODE=fixed DSPARK_TOKENS=7` | Optional; can win in predictable code phases |
| Dynamic depth | `DSPARK_DEPTH_MODE=dynamic DSPARK_TOKENS=7` | Optional load-aware policy |
| Target-only | `MODE=dspark-mtp0` | Performance/correctness baseline |

K7 has reached ~499 tok/s using all seven draft positions in a low-entropy code phase. The
r24-era "SGLang advantage" that made K7 look bad turned out to be a **prompt mismatch** —
matching official-max prompt encoding put both runtimes in the same ~39.8% acceptance
regime. K5 stays the default because it is the better *general* choice, not because K7 is
broken.

For a coding workstation that is worth an experiment: K7 is precisely the case upstream
says can win, and this box's workload is low-entropy code far more often than upstream's
mixed benchmark suite. Change one variable and measure.

`MODE=dspark-mtp0` is the new way to get a target-only baseline without swapping
checkpoints. **Do not use `mtp2` on the 0731 checkpoint** — that mode belongs to the older
`DeepSeek-V4-Flash` checkpoint with its own MTP head; 0731 carries the native DSpark draft
head instead.

### Native L1/L2 KV offload (r33 retained)

`KV_OFFLOADING_SIZE=0` in the command above, so none of this is live yet. r33 retains the
native tiered-offload contract introduced and restart-qualified in r31, and
`machines/desktop/disks.nix` provisions for it.

Native offload is optional and independent from LMCache. `KV_OFFLOADING_SIZE` is total
host **L1** capacity in GiB, and lives in `/dev/shm` — which under `--ipc=host` means the
NixOS host's `boot.devShmSize`, competing with the ARC. The r31 feature retained by r33
is **L2**:
environment-only filesystem configuration, no privileged container:

```bash
docker run ... \
  -e KV_OFFLOADING_SIZE=16 \
  -e NATIVE_L2_PATH=/native-l2 \
  -e NATIVE_L2_GB=512 \
  -v /models/native-l2:/native-l2 \
  ...
```

`NATIVE_L2_PATH` is the path *inside* the container and must be paired with
`NATIVE_L2_GB`. On this box the host side is `/models/native-l2` — its own ZFS dataset,
compression off (FP8 KV blocks do not compress), 1M records, and **quota'd at 512 GiB to
match `NATIVE_L2_GB`**. That pairing is the safety property: without it, `NATIVE_L2_GB` is
a number the runtime respects and the filesystem does not, on a pool that also holds a
155 GiB checkpoint and `/nix`. Raise both together or neither.

The helper builds the transfer JSON and disables expandable CUDA allocator segments,
because the shared host region needs stable registrations — see
[the expandable-segments caveat](#one-upstream-caveat-that-does-apply).

Upstream's restart gate: with a decimal 4.5 GiB L1 and a bounded 4 GiB filesystem L2, a
full engine restart discarded GPU and process-local L1 state, and replaying the same 32k
prompt loaded 303,586,560 bytes from L2 and completed in **0.415 s**. That is the feature
in one sentence — surviving a restart without re-prefilling.

r24's TP2 offload gate, for the L1-only shape, still stands as a sizing reference:
`MAX_MODEL_LEN=131072`, `GPU_MEMORY_UTILIZATION=0.97`, `KV_OFFLOADING_SIZE=5.5`, six
concurrent ~120k-token prompts in 62.153 s, store intervals moving 2.5–2.66 GB in
44–47 ms (~55–56 GB/s).

### What changed between r24 and r33

The changes remain container/runtime-only; none require new host configuration.

**r29** — FULL CUDA graph capture for the DSpark context-KV path. Worth +4.3% at CC1
server decode (190.68 vs 182.82 tok/s); negligible at high concurrency where the GPU is
already compute-saturated. Clean-image validation: 192/192 exact final answers at K5.

**r30** — the correctness one. Declares scheduler-reachable compressed-MLA verifier
capacity instead of assuming a fixed 256 rows, which was **causing correctness failures
above C24**. Also builds native tiered-offload final stores before request-state
finalization (fixing a `KeyError` in `prepare_store()` when deep request queues finalized
state early), isolates semantic PCIe graph channels, and renames the package to the
canonical `b12x` spelling — `SPARKINSET_*` variables survive as compatibility aliases.

**r31** — per upstream's own list:

- Builds FlashInfer from qualified current source plus upstream PR #4393, and exposes
  PCIe IPC all-reduce through vLLM.
- Guards persistent FlashInfer decode wrappers by their planned query length.
- Emits packed UE8M0 scales correctly from compiled QuantFP8, and preserves activation
  dtype for int32-packed MLA weights.
- Uses vLLM's canonical speculative `attention_backend` field for the DSpark draft backend.
- Registers supported GG backend controls instead of reporting them as unknown environment
  variables.
- Deduplicates lockstep native-offload cleanup, bounds filesystem storage, and treats
  stale secondary-tier hits as misses that can be recomputed.
- Prewarms target and native-MTP mixed-Trellis route packing before KV sizing.
- Retains r30's final-store ordering fix and r29's compressed-MLA/FULL-graph row-capacity
  work.

The r31 regression comparison upstream considers valid is TP4 B12X against the previous
TP4 B12X on the same host: 144.5 → 148.4 tok/s at C1, 1,499.2 → 1,511.0 at C32, 15,406 →
16,360 on 8k prefill. Do not read the TP2-vs-TP4 rows as a backend A/B; they are different
parallelism.

The K5 TP4 r31 release gate, for historical reference on what "healthy" looks like in
the logs: 797,049 tokens of GPU KV capacity, 2,540.5 tok/s sustained C64 aggregate decode,
31.36% strict draft acceptance in the C64 window, 64/64 long-context pass, zero
output-cap hits, and zero runtime errors. Acceptance is workload-dependent — that gate is
a correctness and stability test, not an acceptance estimate for your prompts.

**r33** retains those r31 contracts while updating B12X:

- #133 adds topology-scoped fused all-reduce paths, opt-in TP2/TP4 remote push, and the
  qualified automatic TP8 owner-reduction path.
- #135 preserves dense GEMM API contracts for block-FP8 callers.
- #136 restores capture-safe K6 small-M dispatch, gated to exact SM120 capability.
- #137 aligns mixed-Trellis execution with the QSRT ABI.
- The vLLM and FlashInfer integration trees and the 0731 model revision are unchanged.

The r33 release passed its helper, manifest, source-label, launcher-hash, and remote GPU
receipt gates. The focused #136 suite passed nine SM120 tests, including numerical
comparison and CUDA graph replay.

### Context length: still uncertified past ~200k

Unchanged from r24, and worth restating because it is the setting most likely to be
raised on a whim. The 1M envelope lost its endorsement: r24 deleted the Context Length
section that described community runs at `MAX_MODEL_LEN=1048576` with
`MAX_NUM_BATCHED_TOKENS=2048`, and added that "tool/reasoning anomalies reported beyond
roughly 200k context have not been conclusively attributed to one runtime component".
r33 does not restore it.

If you want the long context back, raise both together — `1048576` with `2048` was the
community pairing — and treat anything past ~200k as unverified rather than supported.

### Why r33 and not the SM120 fork

The previous command on this page used
`ghcr.io/ormandj/vllm-deepseek-v4-flash-sm120:v20`, a fork built on the r16 base
(2026-07-31) that carries one patch: `vllm-b12x-compressed-mla-workspace.patch`, a rewrite
of `_reserve_dummy_compressed_mla_scratch` in `vllm/models/deepseek_v4/nvidia/b12x.py`.

r24 shipped [vLLM #229](https://github.com/local-inference-lab/vllm/pull/229) — "sizes
compressed MLA workspaces from the physical cache contract and prevents TP2/K5
long-concurrency under-reservation" — the same code path, upstream, and r29–r33 built
further on it. The fork has published nothing since 2026-08-01 and has no rebuild past
r16. Note this correspondence is inferred from the patch target and the changelog
description, not from diffing #229 itself: if the symptom the fork patched reappears,
that inference is where to look first.

One earlier fix from r24 is worth keeping in view because it applies directly to this box:
[InstantTensor #19](https://github.com/scitix/InstantTensor/pull/19) "retries large
BUFFERED host registration as bounded segments instead of failing the whole model load."
`INSTANTTENSOR_BACKEND=BUFFERED` against a 155 GiB checkpoint is exactly the case where
r16 could abort the load outright.

### The reference Compose profile (r33)

The file the command above is derived from —
[`docker-compose-ds4-v20-r33.yml`](https://raw.githubusercontent.com/local-inference-lab/blackwell-llm-docker/426da51285d0666508003b03a75a442139fb7979/examples/docker-compose-ds4-v20-r33.yml),
pinned at that commit:

```yaml
entrypoint: ["/usr/local/bin/serve-ds4-flash.sh"]
network_mode: host
ipc: host
init: true
gpus: all                   # new in the r31 file
restart: unless-stopped
shm_size: ${SHM_SIZE:-32gb} # inert under ipc: host
# NOTE: no `privileged: true` — it is gone as of r31
ulimits:
  memlock:  { soft: -1, hard: -1 }
  nofile:   { soft: 1048576, hard: 1048576 }
  stack:    67108864
volumes:
  - ${HF_CACHE:-/root/.cache/huggingface}:/root/.cache/huggingface
  - ${MODEL_ROOT:-/root/models}:/root/models:ro
  - ${JIT_CACHE:-./cache/ds4-v20-r33}:/cache
  - ${CONTAINER_TMP:-./cache/ds4-v20-r33/tmp}:/container-tmp
  - ${NATIVE_L2_HOST_PATH:-./cache/ds4-v20-r33/native-l2}:/native-l2
```

Three things changed in the scaffolding since the r24 file, and all three matter:
`privileged` was dropped, `gpus: all` was added (so the Compose path now needs the same
`nvidia-cdi-hook` PATH fix our `docker run` does), and the `native-l2` volume appeared.
`PYTHONHASHSEED=0` and InstantTensor `BUFFERED` are defaults in the environment block.

`/container-tmp` is still a **persistent bind mount inside the JIT cache tree**, not a
tmpfs. Reuse the same `JIT_CACHE` across runs; a tmpfs discards the compiled artifacts
every start — which is why the command above binds `/models/vllm-cache/r33/tmp` rather
than mounting 16 GiB of RAM there. If a run is interrupted during extension compilation,
PyTorch can leave an empty `lock` file in that tree; only delete one after confirming no
compiler process holds it.

On L1 sizing under host IPC, the Compose file is explicit: "Because this compose file uses
host IPC, `/dev/shm` must have that capacity plus normal runtime headroom." So sizing lives
on the NixOS side — `boot.devShmSize` (default `"50%"` of RAM) must exceed
`KV_OFFLOADING_SIZE` plus headroom, and it is sharing RAM with the ARC. With a private
`--shm-size`, size it there instead. Since r24 the backing pathname is unlinked once all
workers have mapped it, which fixed r16's orphaned `/dev/shm/vllm_offload_*.mmap` after a
`SIGKILL`.

### Going headless to free GPU memory

This is the one thing the config actively fights. `roles/dual-desktop-plasma` runs X11 +
SDDM + XMonad **on these same GPUs**, so the X server and framebuffer hold VRAM that
`GPU_MEMORY_UTILIZATION=0.975` assumes it can have. Upstream's headroom numbers (15.27 GiB
for KV at 0.975) come from headless boxes.

**1. Pick a mode at the boot menu (this is already configured)**

`machines/desktop/default.nix` defines a `headless` **specialisation**. systemd-boot
lists specialisations as their own entries, so the boot menu offers:

| Entry | Default unit | What you get |
|---|---|---|
| `NixOS` (default) | `graphical.target` | Workstation — SDDM, XMonad, both monitors |
| `NixOS (headless)` | `multi-user.target` | Text login **on the attached monitor**, GPUs untouched |

> "Headless" is a misleading name for it. The specialisation stops X and SDDM from
> starting; it does not turn off video output. `getty` still runs, so a monitor plugged
> into either card shows a normal text login. It means *no X server holding the GPUs*,
> not *no screen*. This is the entry to pick for any console work on the box — including
> before home-manager has been applied, when the stock XMonad has none of your
> keybindings.

(The entry title comes from `systemd-boot-builder.py`, which formats specialisations as
`"{distro} ({specialisation})"`.)

Everything else is shared: same kernel, same driver, same ZFS pool, same generation.
The specialisation changes one option:

```nix
specialisation.headless.configuration = {
  systemd.defaultUnit = lib.mkForce "multi-user.target";
};
```

Because only the target changes, X is still fully configured in the headless entry —
it just never starts. So you are not locked in:

```bash
sudo systemctl isolate graphical.target    # bring XMonad up, no reboot
sudo systemctl isolate multi-user.target   # drop it again
```

Two things about that one line are load-bearing:

- **`services.xserver.autorun = false` would not work.** nixpkgs sets
  `systemd.defaultUnit = mkIf (xserver.autorun || displayManager.enable) "graphical.target"`
  in `services/misc/graphical-desktop.nix`, and `dual-desktop-plasma` enables SDDM — so
  `displayManager.enable` keeps the graphical target regardless of `autorun`.
- **`mkForce` is required.** That nixpkgs definition is normal priority, so a second
  plain definition is a conflict, not an override.

Building and switching:

```bash
./system-apply.sh                             # builds both; boots the workstation entry
./system-apply.sh --specialisation headless   # builds both; activates headless now
```

`system-apply.sh` forwards its arguments to `nixos-rebuild`, and `nixos-rebuild` builds
every specialisation on any switch — you only ever pick which one to *activate*.

Switching specialisations live does not stop an already-running X server; it only changes
what future boots and target isolations do. To free the VRAM in the current session, use
option 2 or `systemctl isolate multi-user.target`.

**2. Per serving session — stop the display manager**

No reboot, no rebuild. Run it over SSH; it kills your X session.

```bash
sudo systemctl stop display-manager
nvidia-smi --query-gpu=index,memory.used --format=csv   # both GPUs should be ~0 MiB
# ... run the server ...
sudo systemctl start display-manager                    # desktop back
```

The unit is `Restart=always`, but systemd honours an explicit `stop` — it will not come
back on its own.

**3. Never want the desktop — drop the role entirely**

Remove `dual-desktop-plasma` from the `desktop` host's `roles` in `flake.nix`.

**Keep `nvidia-graphics`, and do not touch its `services.xserver.videoDrivers` line.**
The entire `hardware.nvidia` module in nixpkgs is gated on
`lib.elem "nvidia" config.services.xserver.videoDrivers` (`hardware/video/nvidia.nix`), so
dropping that setting silently removes the driver, `nvidia-persistenced`, and the
container toolkit's driver mounts — on a machine with no X to hint that anything is wrong.
Nothing in the module asserts `services.xserver.enable`, so the driver is happy headless.

`nvidiaPersistenced = true` is already set, which is what keeps the driver initialized
with no X client attached — no per-run initialization cost.

**How much does this actually save?** Be sceptical of large claims: X + XMonad with no
compositor is on the order of a few hundred MB per GPU, against the ~2.4 GiB that 0.975
leaves free on a 96 GB card. Measure it rather than assuming — `nvidia-smi
--query-gpu=memory.used --format=csv` before and after step 1.

The stronger argument for headless is not VRAM. X holds a permanent handle on both GPUs,
so you cannot `rmmod nvidia_uvm nvidia_modeset nvidia` to apply modprobe changes (the
`ForceP2P` config) without a full reboot, and a stuck X client can keep the driver busy
while you are trying to reclaim it.

If you want the desktop and the server co-resident anyway, drop utilization to ~0.94 and
expect proportionally less KV cache.

### Why these settings are right for this box

- **`INSTANTTENSOR_BACKEND=BUFFERED`** — the safe choice on ZFS. `BUFFERED` expands to
  `[URING_BUFFERED, AIO_BUFFERED, MMAP]`, tried in that order, so it degrades gracefully
  (io_uring is available here — `kernel.io_uring_disabled` is `0` and nothing overrides
  it). InstantTensor otherwise defaults to Direct I/O and is fastest with `CUFILE`
  (GPUDirect Storage). **Do not switch to `CUFILE`**: GDS requires a filesystem on
  NVIDIA's supported list and ZFS is not on it. Plain Direct I/O is less clear-cut —
  this pool runs ZFS 2.4.3 and O_DIRECT has been supported since 2.3 — so `AIO`/`URING`
  may well work; treat that as an experiment to benchmark, not a free win, since it
  bypasses the ARC on a 1M-recordsize dataset.
- **`/container-tmp` as a bind mount, not a tmpfs** — it lives inside the JIT cache tree
  so compiled artifacts survive restarts. A 16 GiB tmpfs there is faster but discards
  them every start, and costs RAM on top of the model load.
- **`--network host`** — matches the reference profile, and makes the
  `allowedTCPPorts = [ 8000 ]` entry in `machines/desktop/default.nix` load-bearing.
  With `-p 8000:8000` instead, Docker publishes through its own iptables chain and the
  firewall entry becomes irrelevant.
- **`--ulimit memlock=-1 / nofile=1048576 / stack=67108864`** — NixOS leaves dockerd at
  systemd's defaults and containers inherit them, so these have to be asked for
  explicitly. See [the reference Compose profile](#the-reference-compose-profile-r33).
- **No `--privileged`** — dropped upstream in r31, and native L2 was validated without it.
  See the [r33 launch section](#running-deepseek-v4-flash-gilded-gnosis-r33-k5).
- **Storage** — 155 GiB checkpoint on `/models`, a `/cache` on `models/vllm-cache` that
  grows to several GiB of compiled kernels and CUDA graphs, and a quota'd
  `models/native-l2` if you enable the L2 tier. Keep `/cache` persistent: a cold cache
  costs roughly 20 minutes of kernel and CUDA-graph compilation at startup.
- **`ALLREDUCE_MODE`** — `auto` gives TP2 the new FlashInfer PCIe IPC path. B12X wins at
  C1 and prefill, which is where a single-user workstation lives. Benchmark before
  settling. See [All-reduce backend selection](#all-reduce-backend-selection-is-new-allreduce_mode).
- **Driver** — the image is `cu132`; `production` is 595.84, which is new enough.
  Confirm with `nvidia-smi` before blaming the container.

## Notes

- **ZFS + Blackwell + latest kernel** — `pkgs.linuxPackages` currently resolves to 6.18.41, which supports both. If ZFS falls behind mainline in future, pin to an LTS: `kernelPackage = pkgs.linuxPackages_6_12;`.
- **CUDA on host** — deliberately not installed. Use `nvidia/cuda:*` containers for compilation and inference; keeps host lean.
- **Model storage** — `/models` is a dedicated ZFS dataset with 1M recordsize and no compression, tuned for large safetensors/GGUF files. Put HuggingFace cache, Ollama models, etc. there. Its two children (`vllm-cache`, `native-l2`) are tuned differently on purpose; do not flatten them back into the parent.
- **Fan control** — the old motherboard-specific `hardware.fancontrol` block is gone. If the new board needs custom curves, generate config with `pwmconfig` after boot and add it back to `machines/desktop/default.nix`. A `gpuPowerLimitWatts` cap is the cheaper first lever — see [Power limits](#power-limits).
- **Rebuilding the installer** — the ISO is built from this flake, so it goes stale as the flake moves. Rebuild it (`nix build .#installer-iso`) rather than reusing an old stick if `authorized_keys.txt`, the kernel, or `disks.nix` has changed since.
