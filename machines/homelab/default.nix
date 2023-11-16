{ pkgs, lib, config, ...}:
{

  fileSystems."/" =
    { device = "/dev/disk/by-uuid/d49bbbf1-ce0c-43a4-acc6-d34f4cb6ff29";
      fsType = "ext4";
    };

  fileSystems."/boot" =
    { device = "/dev/disk/by-uuid/5DA4-D7A8";
      fsType = "vfat";
    };

  hardware.cpu.amd.updateMicrocode = true;

}

