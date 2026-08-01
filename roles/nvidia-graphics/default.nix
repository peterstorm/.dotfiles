{ pkgs, config, lib, ... }:
{
  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  hardware.nvidia = {
    modesetting.enable = true;
    open = true;
    nvidiaSettings = true;
    nvidiaPersistenced = true;
    # DS4 v8 runs CUDA 13.2.1 inside the vLLM container. `production` currently
    # resolves to driver 595.84 (kernel 6.18) — new enough for cu132. After first
    # boot confirm `nvidia-smi` reports CUDA Version >= 13.2; if a future bump lags,
    # move to `.beta` or `.latest`.
    package = config.boot.kernelPackages.nvidiaPackages.production;
    powerManagement.enable = false;
  };

  hardware.nvidia-container-toolkit.enable = true;

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia
  ];
}
