{ pkgs, lib, config, inputs, ... }:
let
  # Persistent per-GPU power cap in watts, or null to leave the cards at their
  # firmware default. Left null on purpose: the SKU in this box is unrecorded,
  # and the right number differs by card — nvidia-smi exits non-zero if you ask
  # for a limit outside the card's supported range. Read the range with
  #   nvidia-smi -q -d POWER
  # after first boot, then set a number here.
  #
  # Why it is worth setting: upstream's sweep (hardware/blackwell-power-limit-sweep.md)
  # measures the 600 W Workstation card holding ~300-305 Gflop/s/W flat across the
  # whole 200-350 W band and only reaching peak throughput at the full 600 W. Two
  # of those is 1200 W of GPU alone in a consumer ATX case. Capping each around
  # 400-450 W buys back most of the thermals and noise for a few percent of
  # throughput — and on a shared-airflow two-up build, less throttling can leave
  # sustained clocks *higher* than the uncapped pair.
  gpuPowerLimitWatts = null;
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disks.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Two boot entries: the default is the workstation (X11 + SDDM + XMonad on the
  # RTX 6000 Pros), "headless" boots to a console so the GPUs start empty for
  # inference. systemd-boot lists specialisations as their own entries.
  #
  # Only the default systemd unit changes, so the desktop stays one command away:
  #   systemctl isolate graphical.target    # bring XMonad up without rebooting
  #   systemctl isolate multi-user.target   # drop it again
  #
  # mkForce is required, not optional: nixpkgs sets
  #   systemd.defaultUnit = mkIf (xserver.autorun || displayManager.enable) "graphical.target"
  # in services/misc/graphical-desktop.nix. That is a normal-priority definition,
  # so a second one here conflicts rather than overrides — and it is also why
  # `services.xserver.autorun = false` does nothing while SDDM is enabled.
  specialisation.headless.configuration = {
    systemd.defaultUnit = lib.mkForce "multi-user.target";
  };

  # GPU-to-GPU PCIe P2P for multi-GPU inference (DS4 v8 / vLLM b12x allreduce).
  # RTX 6000 Pro (Blackwell) has no NVLink, so the allreduce path relies on
  # PCIe P2P. Disabling IOMMU is the clean direct-attach equivalent of the
  # ACS-override dance needed on PCIe-switch boards, and is required by the
  # nvidia_uvm fix. Requires "Above 4G Decoding" + "Resizable BAR" ON in BIOS.
  #
  # The third parameter is unrelated to P2P. zfs_arc_max caps the ARC at 16 GiB;
  # OpenZFS on Linux otherwise takes half of RAM, which is exactly the half this
  # box needs for something else. Under `--ipc=host` the vLLM KV offload region
  # is an mmap in the host's /dev/shm, and the model load streams a ~155 GiB
  # checkpoint that is read once per start, sequentially, off a 1M-recordsize
  # dataset — so an unbounded ARC evicts pages that are reused to cache data
  # nobody reads twice. 16 GiB is ample for /nix and metadata.
  boot.kernelParams = [ "iommu=off" "amd_iommu=off" "zfs.zfs_arc_max=17179869184" ];
  boot.extraModprobeConfig = ''
    options nvidia_uvm uvm_disable_hmm=1
    options nvidia NVreg_RegistryDwords="ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;GrdmaPciTopoCheckOverride=1;EnableResizableBar=1"
  '';

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "8a3f2c19";

  services.zfs = {
    autoScrub.enable = true;
    trim.enable = true;
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  hardware.cpu.amd.updateMicrocode = true;

  # Always-on workstation with no battery to protect, and a CPU that has to keep
  # up with host-side rejection sampling and input prep on the decode path —
  # those stages are eager, not captured in the CUDA graphs.
  powerManagement.cpuFreqGovernor = "performance";

  # /var/lib/docker is a ZFS dataset (see disks.nix), and dockerd's driver
  # auto-detection cannot land on overlay2 there: moby's overlay2 init refuses
  # ZFS outright, so it falls through to its `zfs` graphdriver. That driver
  # shells out to the `zfs` binary — and the NixOS module only puts
  # `boot.zfs.package` on dockerd's PATH when storageDriver is *explicitly*
  # "zfs". Leaving this unset is the difference between a working daemon and one
  # that fails to find zfs at startup, on the machine whose entire job is running
  # a 155 GiB container.
  virtualisation.docker.storageDriver = "zfs";

  # nvidia-smi -pl, declaratively, surviving reboots. Only defined when a limit
  # is actually chosen — see gpuPowerLimitWatts at the top of this file.
  # nvidiaPersistenced keeps the driver initialized, so the cap is not lost when
  # the last client detaches.
  systemd.services.nvidia-power-limit = lib.mkIf (gpuPowerLimitWatts != null) {
    description = "Persistent power limit for the RTX 6000 Pro cards";
    wantedBy = [ "multi-user.target" ];
    after = [ "nvidia-persistenced.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.hardware.nvidia.package.bin}/bin/nvidia-smi -pl ${toString gpuPowerLimitWatts}";
    };
  };

  # Expose the vLLM / DS4 v8 OpenAI-compatible server (PORT=8000, --network host)
  # to the LAN. sshd opens 22 itself; the wifi role opens 8081. Merges with those.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
