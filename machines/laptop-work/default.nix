{ pkgs, lib, config, ...}:
{

  boot.initrd.luks.devices = {
    root = {
      device = "/dev/nvme0n1p2";
      preLVM = true;
    };
  };

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/a422f57f-f490-46df-8d43-bc660435b040";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/A647-6038";
      fsType = "vfat";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/24f2a3e7-0469-4b5c-88aa-62111314e383"; }
    ];

  hardware.cpu.intel.updateMicrocode = true;

}

