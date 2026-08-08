# Custom NixOS installer image for the `desktop` AI workstation.
#
# The stock minimal ISO needs a monitor, a keyboard, and three manual commands
# (`systemctl start sshd`, `passwd`, `ip addr`) before `nixos-anywhere` can
# reach it. This image needs none of them:
#
#   - your keys from ../../authorized_keys.txt are baked into root and nixos,
#     so sshd accepts you the moment it boots
#   - mDNS publishes it as `installer.local`, so you never have to read an IP
#     off a screen
#   - ZFS is in the running kernel, so disko can create `rpool`
#   - `/etc/os-release` carries VARIANT_ID=installer (from the installation-device
#     profile), which is what makes nixos-anywhere skip its kexec step entirely
#
# With `target` set (the `installer-iso-offline` package) the whole `desktop`
# system closure and its disko script are also in the image's store, so
# `install-desktop` installs the machine with no laptop and no network.
{
  config,
  lib,
  pkgs,
  modulesPath,
  target ? null,
  ...
}:
let
  authorizedKeys = lib.filter (k: k != "") (
    lib.splitString "\n" (builtins.readFile ../../authorized_keys.txt)
  );

  # The hardware questions docs/new-desktop-install.md opens with. Answering them
  # from the ISO matters because PCIe link width decides whether GPU↔GPU P2P — and
  # therefore the whole DS4 inference story — is even possible on this board. That
  # is a reason not to install, so it wants answering before disko wipes anything.
  surveyHardware = pkgs.writeShellApplication {
    name = "survey-hardware";
    runtimeInputs = with pkgs; [
      pciutils
      util-linux
      dmidecode
      nvme-cli
      iproute2
      lshw
      coreutils
      gnugrep
    ];
    text = ''
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo -- "$0" "$@"
      fi

      section() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }

      # Every probe below is `|| true`: this script runs under `set -euo pipefail`
      # and its whole job is to report on unknown hardware. A survey that aborts
      # on the first unavailable field is worse than one that prints a gap.
      section "Board"
      dmidecode -s baseboard-manufacturer || true
      dmidecode -s baseboard-product-name || true
      dmidecode -s bios-version || true

      section "CPU (confirm cpuCores = 16)"
      lscpu | grep -E 'Model name|^CPU\(s\)|Socket|Thread' || true

      section "RAM (drives boot.devShmSize, zramSwap, zfs_arc_max, KV offload)"
      free -g || true

      section "NVMe (confirm disks.nix diskDevice)"
      lsblk -d -o NAME,SIZE,MODEL || true
      nvme list || true

      section "NICs (update NICs in flake.nix)"
      ip -o link show || true

      section "NVIDIA GPUs"
      lspci -nn -d 10de: || true

      # These two are the reason this script exists, so neither may fail quietly.
      # `lspci -vv` reads extended config space and returns *nothing* without
      # root — an empty section looks identical to "no GPUs found", which is
      # exactly the wrong thing to be ambiguous about.
      report() {
        if [ -n "$2" ]; then
          echo "$2"
        else
          printf '!! NO OUTPUT from %s — rerun as root; do not read this as a result.\n' "$1"
        fi
      }

      section "PCIe port path per GPU — THE decisive check"
      echo "Both GPUs must hang off the same bridge. Different bridges means the"
      echo "second card is behind the chipset and PCIe P2P will not work."
      report "lspci -PP" "$(lspci -PP -d 10de: 2>/dev/null || true)"

      section "PCIe link width and speed per GPU"
      echo "LnkSta must show x8 or x16 for BOTH cards. An x4 card is a hardware"
      echo "conclusion, not something to tune around."
      report "lspci -vv" "$(lspci -vv -d 10de: 2>/dev/null | grep -E 'LnkCap:|LnkSta:' || true)"

      printf '\n\033[1mNext:\033[0m record these in the Hardware assumptions table of\n'
      printf 'docs/new-desktop-install.md before installing.\n'
    '';
  };

  # Offline install: disko + nixos-install straight from the store already on
  # this stick. No laptop, no network, no substituters.
  installDesktop = pkgs.writeShellApplication {
    name = "install-desktop";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      # disko partitions and nixos-install writes a bootloader; both need root.
      # Without this the run dies partway through with permission errors, which
      # is a confusing way to learn you forgot `sudo` on a destructive command.
      if [ "$(id -u)" -ne 0 ]; then
        exec sudo -- "$0" "$@"
      fi

      cat <<'EOF'
      This DESTROYS every partition on the disk named in machines/desktop/disks.nix
      (/dev/nvme0n1 unless it was changed) and installs the `desktop` system that
      is baked into this image.

      Run `survey-hardware` first if you have not confirmed the disk and the PCIe
      topology.
      EOF
      printf '\nType YES to continue: '
      read -r confirm
      [ "$confirm" = "YES" ] || { echo "Aborted."; exit 1; }

      echo "==> Partitioning and mounting (disko)"
      ${target.diskoScript}

      echo "==> Installing system closure"
      nixos-install --root /mnt --no-root-passwd --no-channel-copy \
        --system ${target.toplevel}

      cat <<'EOF'

      Done. Reboot, remove the stick, then from your laptop:

        scp -r ~/.dotfiles peterstorm@desktop.local:~/
        ssh peterstorm@desktop.local 'cd ~/.dotfiles && ./hm-apply.sh'
      EOF
    '';
  };
in
{
  imports = [ (modulesPath + "/installer/cd-dvd/installation-cd-minimal.nix") ];

  # ZFS must be in the *running* kernel or disko cannot create rpool — the zfs
  # userland nixos-anywhere uploads is useless without a matching module. Pin the
  # same kernel the desktop uses so the module is known to exist for it.
  boot.supportedFilesystems.zfs = true;
  boot.kernelPackages = lib.mkForce pkgs.linuxPackages;
  boot.zfs.forceImportRoot = false;
  networking.hostId = "8a3f2c19";

  # Blackwell has no nouveau support worth having, and letting it bind the cards
  # is a good way to get a black console on the one boot that needs a screen.
  boot.blacklistedKernelModules = [ "nouveau" ];

  # The point of the exercise: reachable over SSH, by name, with no console.
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = lib.mkForce "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = authorizedKeys;
  users.users.nixos.openssh.authorizedKeys.keys = authorizedKeys;

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    nssmdns4 = true;
  };

  networking.networkmanager.enable = true;
  # The installer's firewall is on by default; nothing here needs a port but 22.
  networking.firewall.allowedTCPPorts = [ 22 ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  environment.systemPackages =
    with pkgs;
    [
      surveyHardware

      # Hardware survey
      pciutils
      usbutils
      nvme-cli
      dmidecode
      lshw
      smartmontools
      ethtool

      # Install and debugging comfort
      disko
      git
      tmux
      htop
      curl
      jq
      rsync
      iperf3
    ]
    ++ lib.optional (target != null) installDesktop;

  services.getty.helpLine = lib.mkForce ''

      NixOS installer for the `desktop` AI workstation.

      SSH is already up and your keys are already installed:

          ssh root@installer.local

      Run `survey-hardware` to answer the hardware questions in
      docs/new-desktop-install.md before installing.

    ${lib.optionalString (target != null) ''
      This image carries the full `desktop` closure. To install with no laptop
      and no network:

          install-desktop

    ''}  From the laptop instead:

          nixos-anywhere --flake .#desktop --target-host root@installer.local
  '';

  # Drives both the image file name and the volume label, so the stick is
  # identifiable as this one rather than a stock minimal ISO.
  # (Kept short: volumeID is edition-derived and hard-capped at 32 characters.)
  isoImage.edition = lib.mkForce (if target != null then "desk-full" else "desktop");
  # The default is zstd level 19. On a plain installer that costs a few minutes;
  # on the offline image, which squashes the entire desktop closure including the
  # NVIDIA driver, it is the difference between minutes and most of an hour, for
  # a stick that gets written once.
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";
  isoImage.storeContents = lib.optionals (target != null) [
    target.toplevel
    target.diskoScript
  ];

  system.stateVersion = "22.11";
}
