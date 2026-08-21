{ pkgs, ... }:
let
  # Nixpkgs' ComfyUI expression replaces caller-supplied Python overrides and
  # therefore resolves to source-built CPU PyTorch on this package set. Build
  # the wrapper environment explicitly from the matching pinned binary wheels.
  # CUDA bindings must move with CUDA 13.2; torch-bin rejects the default 12.9
  # bindings even when its CUDA library set is overridden.
  binaryTorchPython = pkgs.python3.override {
    self = binaryTorchPython;
    packageOverrides = final: prev: {
      cuda-bindings = prev.cuda-bindings.override {
        cudaPackages = pkgs.cudaPackages_13;
      };
      triton = prev.triton-bin.override {
        cudaPackages = pkgs.cudaPackages_13;
      };
      torch = prev.torch-bin.override {
        cudaPackages = pkgs.cudaPackages_13;
        triton = final.triton;
      };
      torchvision = prev.torchvision-bin.override {
        cudaPackages = pkgs.cudaPackages_13;
        torch-bin = final.torch;
      };
      torchaudio = prev.torchaudio-bin.override {
        cudaPackages = pkgs.cudaPackages_13;
        torch-bin = final.torch;
      };
    };
  };

  comfyPythonEnv = binaryTorchPython.withPackages (
    pythonPackages: with pythonPackages; [
      aiohttp
      alembic
      av
      blake3
      comfy-aimdo
      comfy-angle
      comfy-kitchen
      comfyui-embedded-docs
      comfyui-frontend-package
      comfyui-workflow-templates
      einops
      filelock
      kornia
      numpy
      pillow
      psutil
      pydantic
      pydantic-settings
      pyopengl
      pyyaml
      requests
      safetensors
      scipy
      sentencepiece
      simpleeval
      spandrel
      sqlalchemy
      tokenizers
      torch
      torchaudio
      torchsde
      torchvision
      tqdm
      transformers
      yarl
    ]
  );

  # Reuse Nixpkgs' pinned source, patches, metadata, and native wrapper tool;
  # replace only the Python environment captured by the generated executable.
  comfyui = pkgs.comfyui.overrideAttrs (old: {
    installPhase = ''
      runHook preInstall
      mkdir -p $out/share/comfyui $out/bin
      cp -r . $out/share/comfyui
      makeWrapper ${pkgs.lib.getExe comfyPythonEnv} $out/bin/comfyui \
        --add-flags "$out/share/comfyui/main.py" \
        --unset NIX_PYTHONPATH \
        --unset PYTHONPATH
      runHook postInstall
    '';
    installCheckPhase = ''
      runHook preInstallCheck
      "$out/bin/comfyui" --help
      export XDG_DATA_HOME="$(mktemp -d)"
      "$out/bin/comfyui" --cpu --quick-test-for-ci
      runHook postInstallCheck
    '';
    passthru = old.passthru // {
      python = binaryTorchPython;
      pythonEnv = comfyPythonEnv;
    };
  });

  modelTools = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.huggingface-hub
  ]);

  musePromptNode = pkgs.runCommand "comfyui-muse-glimmer-prompt" { } ''
    install -Dm444 \
      ${../../comfyui/custom_nodes/muse_glimmer_prompt/__init__.py} \
      "$out/muse_glimmer_prompt/__init__.py"
  '';

  extraPaths = pkgs.writeText "comfyui-workstation-paths.yaml" ''
    workstation_models:
      base_path: /models/comfyui
      checkpoints: checkpoints
      diffusion_models: diffusion_models
      text_encoders: text_encoders
      clip_vision: clip_vision
      vae: vae
      loras: loras
      controlnet: controlnet
      upscale_models: upscale_models
      audio_encoders: audio_encoders

    declarative_nodes:
      custom_nodes: ${musePromptNode}
  '';
in
{
  environment.systemPackages = [
    comfyui
    modelTools
    pkgs.ffmpeg-full
  ];

  # Large model artifacts are mutable operational data, not Nix-store inputs.
  # The downloader writes only SHA-pinned, checksum-verified files here.
  systemd.tmpfiles.rules = [
    "d /models/comfyui 0750 peterstorm users - -"
    "d /models/comfyui/checkpoints 0750 peterstorm users - -"
    "d /models/comfyui/diffusion_models 0750 peterstorm users - -"
    "d /models/comfyui/text_encoders 0750 peterstorm users - -"
    "d /models/comfyui/clip_vision 0750 peterstorm users - -"
    "d /models/comfyui/vae 0750 peterstorm users - -"
    "d /models/comfyui/loras 0750 peterstorm users - -"
    "d /models/comfyui/controlnet 0750 peterstorm users - -"
    "d /models/comfyui/upscale_models 0750 peterstorm users - -"
    "d /models/comfyui/audio_encoders 0750 peterstorm users - -"
  ];

  systemd.services.comfyui = {
    description = "Nix-managed ComfyUI creative workstation";
    # Installed declaratively but activated explicitly: the normal Qwen TP2
    # backend owns both GPUs, so boot-starting ComfyUI would create contention.
    wants = [
      "network-online.target"
      "nvidia-power-limit.service"
    ];
    after = [
      "network-online.target"
      "nvidia-persistenced.service"
      "nvidia-power-limit.service"
    ];

    environment = {
      HOME = "/home/peterstorm";
      XDG_DATA_HOME = "/var/lib/comfyui";
      XDG_CACHE_HOME = "/var/cache/comfyui";
      HF_HOME = "/var/cache/comfyui/huggingface";
      CUDA_DEVICE_ORDER = "PCI_BUS_ID";
      # Keep physical GPU0 available for Muse Glimmer. Inside ComfyUI this card
      # becomes logical cuda:0; do not also pass --cuda-device 1.
      CUDA_VISIBLE_DEVICES = "1";
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
      MUSE_GLIMMER_BASE_URL = "http://127.0.0.1:8001/v1";
      MUSE_GLIMMER_API_KEY_FILE = "/home/peterstorm/.config/muse-glimmer/api-key";
    };

    serviceConfig = {
      Type = "simple";
      User = "peterstorm";
      Group = "users";
      SupplementaryGroups = [
        "video"
        "render"
      ];
      WorkingDirectory = "/var/lib/comfyui";
      StateDirectory = "comfyui";
      StateDirectoryMode = "0750";
      CacheDirectory = "comfyui";
      CacheDirectoryMode = "0750";
      UMask = "0077";
      ExecStart = ''
        ${comfyui}/bin/comfyui \
          --listen 127.0.0.1 \
          --port 8188 \
          --disable-auto-launch \
          --base-directory /var/lib/comfyui \
          --extra-model-paths-config ${extraPaths} \
          --reserve-vram 8 \
          --preview-method auto \
          --max-upload-size 2048
      '';
      Restart = "on-failure";
      RestartSec = "5s";
      TimeoutStopSec = "30s";
      KillSignal = "SIGINT";

      # ComfyUI has no production-grade authentication. It is deliberately
      # loopback-only and reached through SSH forwarding, never a LAN firewall
      # exception. Partner nodes still need outbound HTTPS.
      NoNewPrivileges = true;
      CapabilityBoundingSet = "";
      LockPersonality = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = "read-only";
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      ReadOnlyPaths = [ "/models/comfyui" ];
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };

  # Intentionally no firewall rule for 8188 and no ComfyUI-Manager package.
  # Core 0.31.1 already contains Krea 2, local H3, hosted H3, and media nodes;
  # mutable pip/git installs would make the Nix service non-reproducible.
}
