{ pkgs, lib, config, inputs, ... }:
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
  boot.kernelParams = [ "iommu=off" "amd_iommu=off" ];
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

  # Expose the vLLM / DS4 v8 OpenAI-compatible server (PORT=8000, --network host)
  # to the LAN. sshd opens 22 itself; the wifi role opens 8081. Merges with those.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
