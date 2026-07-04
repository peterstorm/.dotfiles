{ pkgs, lib, config, inputs, ... }:
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disks.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

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
}
