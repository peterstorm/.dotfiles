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

  system.activationScripts = {
    # This is required to run third-party dynamically linked binaries
    # which expect their interpreter to be in the standard Linux FSH.
    ldso = lib.stringAfter [ "usrbinenv" ] ''
      mkdir -m 0755 -p /lib64
      ln -sfn ${pkgs.glibc.out}/lib64/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2.tmp
      mv -f /lib64/ld-linux-x86-64.so.2.tmp /lib64/ld-linux-x86-64.so.2 # atomically replace
    '';
  };

}

