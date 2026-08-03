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

  # Make `docker run --gpus all` work, not just `--device=nvidia.com/gpu=all`.
  #
  # Since moby 29.2 (PR #50228) dockerd translates --gpus into a CDI request, but
  # only if it can `exec.LookPath("nvidia-cdi-hook")` at daemon startup. NixOS
  # gives dockerd a minimal unit PATH (kmod, coreutils, findutils, grep, sed,
  # systemd), so the lookup fails, no "gpu" capability is registered, and --gpus
  # dies with `could not select device driver "" with capabilities: [[gpu]]`.
  # The toolkit's `tools` output carries nvidia-cdi-hook; put it on that PATH.
  systemd.services.docker.path = [
    (lib.getOutput "tools" config.hardware.nvidia-container-toolkit.package)
  ];

  environment.systemPackages = with pkgs; [
    nvtopPackages.nvidia
  ];
}
