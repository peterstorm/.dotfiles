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

  hardware.fancontrol = {
    enable = true;
    config = ''
      Common Settings:
      INTERVAL=10

      Settings of hwmon3/pwm3:
      Depends on hwmon0/temp3_input
      Controls hwmon3/fan3_input
      '  MINTEMP=20
      MAXTEMP=60
      MINSTART=150
      MINSTOP=100

      Settings of hwmon3/pwm2:
      Depends on hwmon0/temp3_input
      Controls hwmon3/fan2_input
      MINTEMP=20
      MAXTEMP=60
      MINSTART=150
      MINSTOP=100

      Settings of hwmon3/pwm1:
      Depends on hwmon0/temp3_input
      Controls hwmon3/fan1_input
      MINTEMP=20
      MAXTEMP=60
      MINSTART=150
      MINSTOP=100
    '';
  };

}

