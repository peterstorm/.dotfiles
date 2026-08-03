# New Desktop (AI Workstation) — NixOS Install Guide

Target machine: AMD Ryzen + 2× NVIDIA RTX 6000 Pro (Blackwell), WiFi + Ethernet, single NVMe, ZFS root, X11 + SDDM + XMonad dual-monitor.

Host name: `desktop`. Everything is declarative — one command from the laptop wipes and installs.

## Hardware assumptions (verify on first boot)

Nothing in this repo records the actual parts. What follows is what the config *implies*,
what is merely assumed, and which assumptions other sections lean on. Fill these in once
the box boots — several tuning numbers below are wrong if they are wrong.

| Item | Basis | Assumed | Where it matters |
|---|---|---|---|
| CPU | `cpuCores = 16`, `kvm-amd` | Ryzen 16-core (9950X-class, AM5) | PCIe lanes — see below |
| GPUs | prose only | 2× RTX PRO 6000 Blackwell, 96 GB each | `GPU_MEMORY_UTILIZATION=0.975` assumes 96 GB |
| GPU variant | unrecorded | unknown: Workstation (600W) or Max-Q (300W) | PSU, thermals, sustained clocks |
| RAM | unrecorded | **unknown** | `/dev/shm` = 50%, zram = 50%, KV-offload ceiling |
| PCIe topology | unrecorded | **unknown** | whether GPU↔GPU P2P works at all |
| NVMe | `/dev/nvme0n1` | first slot | disko wipes this device |
| NICs | `[ "wlp5s0" "enp6s0" ]` | guessed | non-blocking, NetworkManager copes |

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

```bash
free -g                                        # RAM — drives /dev/shm, zram, KV offload
nvidia-smi -q -d POWER | grep -i "power limit" # 600W Workstation vs 300W Max-Q
nvidia-smi --query-gpu=memory.total --format=csv
lscpu | grep -E "Model name|^CPU\(s\)"         # confirm cpuCores = 16
ip -o link show                                # confirm the NIC names
lsblk -d -o NAME,SIZE,MODEL                    # confirm /dev/nvme0n1
```

RAM is the one to write down. With `--ipc=host`, the container's `/dev/shm` is the host's
`boot.devShmSize` (default `"50%"`), so 64 GB of RAM means a 32 GB shm ceiling — enough
for serving, but not for `KV_OFFLOADING_SIZE=48.5`. `zramSwap.memoryPercent = 50` is also
sized off it.

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
  - `specialisation.headless` — a second systemd-boot entry that boots to a console
    instead of SDDM/XMonad, so the GPUs start empty for inference. See
    [Going headless](#going-headless-to-free-gpu-memory)
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
| `flake.nix` (desktop) | `NICs` | `[ "wlp5s0" "enp6s0" ]` | Update once you know real interface names (`ip -o link show`). Non-blocking — NetworkManager handles the rest |
| `machines/desktop/default.nix` | `networking.hostId` | `"8a3f2c19"` | Only if it collides with an existing host |
| `flake.nix` (desktop) | `cpuCores` | `16` | Set to actual core count for build parallelism |
| `roles/dual-desktop-plasma/default.nix` | xrandr `setupCommands` | `DP-2` primary, `DP-0` rotated | **Will differ on this box** — two GPUs spread connectors across `DP-0..DP-3`. Check `xrandr` after boot and update, or monitors won't be positioned (non-fatal — greeter xrandr just no-ops) |
| `authorized_keys.txt` | your pubkey | 4 keys | Must contain the key you SSH from — the `ssh` role is publickey-only |

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
- BIOS (for multi-GPU P2P — see DS4 v8 section below): **Above 4G Decoding = ON**, **Resizable BAR = ON**.
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

Once the machine reboots into the installed system, the `ssh` role's sshd is running
(publickey-only) and accepts your key from `authorized_keys.txt` for `peterstorm`.

> **Password:** `users.mutableUsers = false`, so runtime `passwd` does **not** persist —
> it reverts on the next `system-apply.sh` run. The console/SDDM password is the
> declarative `initialPassword` (`hunter2`, from `lib/user.nix`). To set a real one,
> add a `hashedPasswordFile` (sops) to the user rather than running `passwd`. For
> headless use you can ignore it and stay on key-based SSH.

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

Run the [hardware assumptions](#hardware-assumptions-verify-on-first-boot) checks first —
this is the moment the PCIe topology and RAM questions get answered. Then:

```bash
nvidia-smi                             # both RTX 6000 Pro cards listed, CUDA Version >= 13.2
nvtop                                  # live view
cat /proc/driver/nvidia/params | grep RegistryDwords   # ForceP2P=0x11;... took effect
zpool status                           # rpool ONLINE, all datasets mounted
zfs list                               # confirm root/nix/home/docker/models

# Container GPU passthrough — both forms should work (see the nvidia-graphics notes)
docker run --rm --device=nvidia.com/gpu=all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
docker run --rm --gpus all              nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

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
ssh peterstorm@desktop
cd ~/.dotfiles
./system-apply.sh          # the script already hardcodes `switch`; a second one errors
```

To wipe and reinstall from scratch (destructive!), boot the USB again and re-run `nixos-anywhere`.

## Running DS4 v8 (DeepSeek-V4-Flash on vLLM)

Guide: <https://github.com/local-inference-lab/rtx6kpro/blob/master/models/ds4dspark-v8.md>
Host prep reference: <https://github.com/local-inference-lab/rtx6kpro/blob/master/optimization/nccl-tuning.md>
and <https://github.com/local-inference-lab/rtx6kpro/blob/master/optimization/pcie-oneshot-allreduce.md>

Everything (CUDA 13.2.1, PyTorch 2.12, vLLM) ships **inside the pinned container**
(`voipmonitor/vllm:eldritch-enlightenment-v2226f26-b12x15cd38c-cu132-20260629`). The host
only provides driver + P2P plumbing. The guide's own launch example is `GPUS=0,1 TP=2` —
exactly our 2-card single-node case, so TP2 is a first-class supported mode.

For the image actually being run on this box, see
[Running DeepSeek-V4-Flash (Gilded Gnosis r24, K5)](#running-deepseek-v4-flash-gilded-gnosis-r24-k5)
below — same host prep,
different container.

### Host prep (already baked into the flake)

- `machines/desktop/default.nix` sets `boot.kernelParams = [ "iommu=off" "amd_iommu=off" ]`
  and the nvidia / nvidia_uvm modprobe overrides (`ForceP2P`, `EnableResizableBar`,
  `uvm_disable_hmm`). RTX 6000 Pro has no NVLink, so the vLLM b12x PCIe allreduce and
  `NCCL_P2P_LEVEL=SYS` depend on GPU↔GPU PCIe P2P working. On a direct-attach desktop
  board, `iommu=off` is the clean equivalent of the ACS-override `setpci` dance that
  PCIe-switch server boards need — skip all of that.
- `roles/nvidia-graphics/default.nix` uses the `production` driver with `open = true`
  (required for Blackwell). `production` currently resolves to **driver 595.84 on kernel
  6.18.41** — confirmed new enough for the container's CUDA 13.2. Still worth a glance:
  after first boot verify `nvidia-smi` shows CUDA Version ≥ 13.2.

The `NVreg_RegistryDwords` string in `machines/desktop/default.nix` is copied verbatim
from the upstream direct-attach P2P fix (`optimization/pcie-oneshot-allreduce.md`), and
`uvm_disable_hmm=1` + `iommu=off amd_iommu=off` are both explicit upstream requirements
(`optimization/nccl-tuning.md` — without them NCCL P2P locks up and NCCL hangs).

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

### Reaching the server from the LAN

`machines/desktop/default.nix` opens TCP **8000** in the firewall, so the vLLM
OpenAI-compatible endpoint (`PORT=8000`, container runs `--network host`) is reachable
at `http://desktop:8000/v1` from other LAN machines. Change the port there if you launch
the server on a different one.

That firewall entry only matters under `--network host`, which both the DS4 v8 helper and
the r24 profile use. If you swap in `-p 8000:8000`, Docker publishes through its own
iptables chain and the port is reachable whether or not it is in `allowedTCPPorts`.

### Model cache → /models

The checkpoint is ~155 GiB. Keep it on the dedicated `/models` ZFS dataset
(recordsize=1M, compression=off — tuned for pre-compressed weights).

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
the BIOS I flat out disabled". So a **firmware** ACS toggle may still matter here even
though the runtime override does not. With `iommu=off` there is no translation for ACS to
force upstream, so it should be moot — but if P2P misbehaves and the BIOS offers the
switch, it costs nothing to try. That thread also records a working alternative to
`iommu=off` entirely: `amd_iommu=on iommu=pt` with ACS disabled in firmware.

## Running DeepSeek-V4-Flash (Gilded Gnosis r24, K5)

The official r24 release image on the r24 release profile, adapted for this box. Same
CUDA 13.2 / B12X lineage as the DS4 v8 guide above, same host prep: ForceP2P modprobe
config, `iommu=off amd_iommu=off`, ReBAR + Above 4G in BIOS.

```bash
docker run --rm --init \
  --name ds4-0731-r24 \
  --gpus all \
  --ipc=host \
  --privileged \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  -v /models/DeepSeek-V4-Flash-0731:/models/deepseek-ai/DeepSeek-V4-Flash-0731:ro \
  -v /models/vllm-cache/r24:/cache \
  -v /models/vllm-cache/r24/tmp:/container-tmp \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_API_KEY='<API_KEY>' \
  -e SERVED_MODEL_NAME=deepseek-v4-flash \
  -e MODEL_PATH=/models/deepseek-ai/DeepSeek-V4-Flash-0731 \
  -e PORT=8000 \
  -e MODE=dspark -e DSPARK_DEPTH_MODE=fixed -e DSPARK_TOKENS=5 \
  -e DRAFT_SAMPLE_METHOD=greedy \
  -e BACKEND=b12x-a8 -e TP_SIZE=2 -e DCP_SIZE=1 \
  -e MAX_NUM_SEQS=16 -e MAX_MODEL_LEN=131072 -e MAX_NUM_BATCHED_TOKENS=8192 \
  -e GPU_MEMORY_UTILIZATION=0.975 \
  -e LOAD_FORMAT=instanttensor -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e KV_OFFLOADING_SIZE=0 \
  voipmonitor/vllm:gilded-gnosis-v20-vllmf5981f1-si2b9bf2a-fi801d57a-cu132-20260803-r24@sha256:64b94299abdd3bcf5bb5050ca91b378f9ee4e0b0eff4748375b95352371d7cb2 \
  /usr/local/bin/serve-ds4-flash.sh
```

```bash
curl -fsS http://127.0.0.1:8000/health
docker logs -f ds4-0731-r24
```

The env block is the r24 release profile verbatim. Leave `MAX_CUDAGRAPH_CAPTURE_SIZE`
unset — the helper derives the graph cap from concurrency and verifier width, which for
fixed K5 at 16 sequences is `16 * (5 + 1) = 96`.

**Deviations from upstream's Compose file, and why:**

| Change | Reason |
|---|---|
| `--gpus all` | Works here because of `systemd.services.docker.path` in `roles/nvidia-graphics`. `--device=nvidia.com/gpu=all` is the equivalent needing no host-side help. |
| Explicit model mount + `MODEL_PATH` | Compose defaults to scanning `${MODEL_ROOT:-/root/models}`. Pointing straight at the checkpoint skips the HF cache mount entirely. |
| Caches under `/models/vllm-cache/r24` | The `/models` ZFS dataset, rather than a relative `./cache` next to a git checkout. |
| `CUDA_DEVICE_ORDER=PCI_BUS_ID` | Makes `CUDA_VISIBLE_DEVICES=0,1` match `nvidia-smi` ordering instead of driver enumeration order. |
| `--rm` instead of `restart: unless-stopped` | The two are mutually exclusive in `docker run`. Drop `--rm` and add `--restart unless-stopped` for a long-lived server. |

Three judgement calls worth knowing about:

- **`--privileged` is upstream's choice, not a verified requirement.** The Compose file
  has carried it since r16 with no stated rationale; the plausible reasons are the pinned
  host memory registration and P2P BAR paths. It is a large grant — worth testing without
  it once the stack is known-good, rather than adopting permanently on faith.
- **`--ipc=host` with no `--shm-size`.** The Compose file sets both, but `shm_size` is
  inert under host IPC — measured: `--ipc=host --shm-size=1g` yields the host's 7.7G
  `/dev/shm`, while `--shm-size=1g` alone yields exactly 1.0G. Under host IPC the
  governing number is the NixOS host's `boot.devShmSize` (default `"50%"` of RAM). If you
  would rather have a private, RAM-independent arena, drop `--ipc=host` and use
  `--shm-size=32g` instead — but see the KV-offload note below before choosing.
- **`DRAFT_SAMPLE_METHOD=greedy` is not part of the r24 profile.** It is carried over
  from the previous command and is not in the Compose file, so the helper's own default
  would otherwise apply. Drop it if you want the release profile exactly.

`--network host` means the vLLM endpoint binds every interface, so the
`allowedTCPPorts = [ 8000 ]` entry in `machines/desktop/default.nix` is what makes
`http://desktop:8000/v1` reachable. `VLLM_API_KEY` is doing the access control — keep it
set. For a contained alternative, swap `--network host` for `-p 8000:8000`.

### Why r24 and not the SM120 fork

The previous command on this page used
`ghcr.io/ormandj/vllm-deepseek-v4-flash-sm120:v20`, a fork built on the r16 base
(2026-07-31) that carries one patch: `vllm-b12x-compressed-mla-workspace.patch`, a rewrite
of `_reserve_dummy_compressed_mla_scratch` in `vllm/models/deepseek_v4/nvidia/b12x.py`.

r24 ships [vLLM #229](https://github.com/local-inference-lab/vllm/pull/229) — "sizes
compressed MLA workspaces from the physical cache contract and prevents TP2/K5
long-concurrency under-reservation" — the same code path, upstream. The fork has published
nothing since 2026-08-01 and has no r24 rebuild. Note this correspondence is inferred from
the patch target and the changelog description, not from diffing #229 itself: if the
symptom the fork patched reappears under r24, that inference is where to look first.

### r24 (2026-08-03) — what else changed since r16

Runbook: <https://github.com/local-inference-lab/rtx6kpro/blob/master/models/ds4dspark-v20.md>
Compose: [`blackwell-llm-docker@build/gilded-gnosis-r21-ds4-runtime-20260802`](https://github.com/local-inference-lab/blackwell-llm-docker/tree/build/gilded-gnosis-r21-ds4-runtime-20260802)

```text
voipmonitor/vllm:gilded-gnosis-v20-vllmf5981f1-si2b9bf2a-fi801d57a-cu132-20260803-r24
manifest sha256:64b94299abdd3bcf5bb5050ca91b378f9ee4e0b0eff4748375b95352371d7cb2
```

Nothing about the host config changes between r16 and r24 — same CUDA 13.2, same B12X
path, same P2P requirements. What changed is the runtime, and the profile defaults now
baked into the command above.

**`DSPARK_TOKENS=7` is actively discouraged**, which is why the command uses K5. r24
publishes matched TP2 numbers:

| Draft depth | Sustained decode | Coding median |
|---|---:|---:|
| K5 | 217.8 tok/s | 289.4 tok/s |
| K7 | 192.1 tok/s | 281.2 tok/s |

K7 is both slower and carries an open defect — "K7 long-context output/tool/BOS
corruption is not closed" in Known Open Items. The r16 runbook explains where a `7`
comes from in the first place: the Compose profile "intentionally selects K5 even though
the generic launcher retains K7 as its neutral default". It is a fallback, not a
recommendation.

**The 1M context envelope lost its endorsement**, which is why the command now uses
`131072` / `8192`. The old `MAX_MODEL_LEN=1048576` with `MAX_NUM_BATCHED_TOKENS=2048`
matched the r16 runbook's Context Length section exactly ("community runs reported ... up
to 1M with a 2048 budget, but those envelopes are not certified"). **r24 deletes that
section** and adds: "Tool/reasoning anomalies reported beyond roughly 200k context have
not been conclusively attributed to one runtime component."

If you want the long context back, raise both together — `MAX_MODEL_LEN=1048576` with
`MAX_NUM_BATCHED_TOKENS=2048` was the community pairing — and treat anything past ~200k
as unverified rather than supported.

**InstantTensor gets a reliability fix that applies directly to this setup.**
[InstantTensor #19](https://github.com/scitix/InstantTensor/pull/19) "retries large
BUFFERED host registration as bounded segments instead of failing the whole model load."
`INSTANTTENSOR_BACKEND=BUFFERED` against a 155 GiB checkpoint is exactly the case where
r16 can abort the load outright.

Also in r24: PCIe graph channel separation (vLLM #216), CUDA IPC graph-state lifetime
hardening (SparkInfer #113), compressed-MLA page-stride correctness (SparkInfer #106),
and native-offload registration alignment (#217/#218). LMCache is updated but explicitly
"remains experimental for DS4".

#### The reference Compose profile

For comparison, the file the command above is derived from. Its scaffolding is unchanged
since r16 — the `ulimits`, `privileged`, and host IPC/networking are not new in r24:

```yaml
network_mode: host
ipc: host
shm_size: 32gb              # inert under ipc: host
privileged: true
init: true
ulimits:
  memlock:  { soft: -1, hard: -1 }
  nofile:   { soft: 1048576, hard: 1048576 }
  stack:    67108864
volumes:
  - ${JIT_CACHE:-./cache/ds4-v20-r24}:/cache
  - ${CONTAINER_TMP:-./cache/ds4-v20-r24/tmp}:/container-tmp
```

Note that `/container-tmp` is a **persistent bind mount inside the JIT cache tree**, not a
tmpfs. r24's First-Run Compile Cache section says to reuse the same `JIT_CACHE` across
runs, and a tmpfs discards those artifacts every start — which is why the command above
binds `/models/vllm-cache/r24/tmp` rather than mounting 16 GiB of RAM there. If a run is
interrupted during extension compilation, PyTorch can leave an empty `lock` file in that
tree; only delete one after confirming no compiler process holds it.

#### If you enable native KV offload

`KV_OFFLOADING_SIZE` is `0` here, so this does not bite yet — but it changes the shm
calculus completely when it does. The offload region is **one process-shared mmap in the
host's `/dev/shm`**, and the Compose file says so directly: "Because this compose file
uses host IPC, `/dev/shm` must have that capacity plus normal runtime headroom."

So with `ipc: host`, sizing lives on the NixOS side — `boot.devShmSize` (default `"50%"`
of RAM) must exceed the offload size plus headroom. With a private `--shm-size`, size it
there instead. r24 also unlinks the backing pathname once all workers have mapped it,
which fixes r16's orphaned `/dev/shm/vllm_offload_*.mmap` after a `SIGKILL`.

r24's own TP2 offload gate: `MAX_MODEL_LEN=131072`, `GPU_MEMORY_UTILIZATION=0.97`,
`KV_OFFLOADING_SIZE=5.5`, six concurrent ~120k-token prompts in 62.153 s, store intervals
moving 2.5–2.66 GB in 44–47 ms (~55–56 GB/s).

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
| `NixOS (headless)` | `multi-user.target` | Console login, GPUs untouched |

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
  explicitly. See [the reference Compose profile](#the-reference-compose-profile).
- **Storage** — 155 GiB checkpoint on `/models`, plus a `/cache` that grows to several
  GiB of compiled kernels and CUDA graphs. Keep `/cache` persistent: a cold cache costs
  roughly 20 minutes of kernel and CUDA-graph compilation at startup.
- **Driver** — the image is `cu132`; `production` is 595.84, which is new enough.
  Confirm with `nvidia-smi` before blaming the container.

## Notes

- **ZFS + Blackwell + latest kernel** — `pkgs.linuxPackages` currently resolves to 6.18.41, which supports both. If ZFS falls behind mainline in future, pin to an LTS: `kernelPackage = pkgs.linuxPackages_6_12;`.
- **CUDA on host** — deliberately not installed. Use `nvidia/cuda:*` containers for compilation and inference; keeps host lean.
- **Model storage** — `/models` is a dedicated ZFS dataset with 1M recordsize and no compression, tuned for large safetensors/GGUF files. Put HuggingFace cache, Ollama models, etc. there.
- **Fan control** — the old motherboard-specific `hardware.fancontrol` block is gone. If the new board needs custom curves, generate config with `pwmconfig` after boot and add it back to `machines/desktop/default.nix`.
