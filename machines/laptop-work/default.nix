{ pkgs, lib, config, ...}:
{

  boot.initrd.luks.devices = {
    root = {
      device = "/dev/nvme0n1p2";
      preLVM = true;
    };
  };

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/11374d4d-27ea-465c-919d-5554be3af4be";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/F800-7BD7";
      fsType = "vfat";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/0ade5970-fd1f-48d0-a315-b5b52099e63b"; }
    ];

  hardware.cpu.intel.updateMicrocode = true;

}

