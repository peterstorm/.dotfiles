{ pkgs, lib, config, ...}:
{

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/4599e228-a6ce-4bf8-82da-f900e46b508d";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/DDF7-F2D8";
      fsType = "vfat";
    };

  swapDevices =
    [ { device = "/dev/disk/by-uuid/edab49d9-d6b5-47ef-a74f-c1edf349069e"; }
    ];

  hardware.cpu.amd.updateMicrocode = true;

}

