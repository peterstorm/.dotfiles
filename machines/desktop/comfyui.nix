{ pkgs, ... }:
let
  # Nixpkgs' ComfyUI expression replaces caller-supplied Python overrides and
  # therefore resolves to source-built CPU PyTorch on this package set. Build
  # the wrapper environment explicitly from the matching pinned binary wheels.
  # CUDA bindings must move with CUDA 13.2; torch-bin rejects the default 12.9
  # bindings even when its CUDA library set is overridden.
  # Nixpkgs enables NVSHMEM's exhaustive test/example compile even though its
  # check phase is disabled. Neither output is installed or used by PyTorch;
  # suppressing them avoids compiling every collective for every CUDA arch.
  binaryCudaPackages = pkgs.cudaPackages_13.overrideScope (
    _final: prev: {
      libnvshmem = prev.libnvshmem.overrideAttrs (old: {
        cmakeFlags = old.cmakeFlags ++ [
          (pkgs.lib.cmakeBool "NVSHMEM_BUILD_TESTS" false)
          (pkgs.lib.cmakeBool "NVSHMEM_BUILD_EXAMPLES" false)
        ];
      });
    }
  );

  binaryTorchPython = pkgs.python3.override {
    self = binaryTorchPython;
    packageOverrides = final: prev: {
      cuda-bindings = prev.cuda-bindings.override {
        cudaPackages = binaryCudaPackages;
      };
      triton = prev.triton-bin.override {
        cudaPackages = binaryCudaPackages;
      };
      torch =
        (prev.torch-bin.override {
          cudaPackages = binaryCudaPackages;
          triton = final.triton;
        }).overridePythonAttrs
          (old: {
            # The cu130 wheel still declares setuptools<82. Nixpkgs' source Torch
            # recipe removes the same stale cap; Torch itself imports with 83.
            pythonRelaxDeps = (old.pythonRelaxDeps or [ ]) ++ [ "setuptools" ];
          });
      torchvision = prev.torchvision-bin.override {
        cudaPackages = binaryCudaPackages;
        torch-bin = final.torch;
      };
      torchaudio =
        (prev.torchaudio-bin.override {
          cudaPackages = binaryCudaPackages;
          torch-bin = final.torch;
        }).overrideAttrs
          {
            # Nixpkgs' 2.11 wheel hash resolves to CUDA 12 regardless of the
            # package-set override. Pin upstream's matching cu130 wheel instead.
            src = pkgs.fetchurl {
              url = "https://download.pytorch.org/whl/cu130/torchaudio-2.11.0%2Bcu130-cp314-cp314-manylinux_2_28_x86_64.whl";
              hash = "sha256-N4tJZxtYERSi0l1Ako8SoVCHL+rfEWaaY/Vz6Bx4AZo=";
            };
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
      imageio
      imageio-ffmpeg
      kornia
      numpy
      opencv4
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
      toml
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

  modelSubdirectories = [
    "checkpoints"
    "diffusion_models"
    "text_encoders"
    "clip_vision"
    "vae"
    "loras"
    "controlnet"
    "upscale_models"
    "audio_encoders"
  ];

  musePromptNode = pkgs.runCommand "comfyui-muse-glimmer-prompt" { } ''
    install -Dm444 \
      ${../../comfyui/custom_nodes/muse_glimmer_prompt/__init__.py} \
      "$out/muse_glimmer_prompt/__init__.py"
  '';

  krea2EditNode = pkgs.fetchFromGitHub {
    owner = "lbouaraba";
    repo = "comfyui-krea2edit";
    rev = "bdfa8b267fdb13730868d435b277dcfe696ec083";
    hash = "sha256-/uK+MV+x2W1Gpm3vo54154fjGcUebNRPhPByS5ms2Qk=";
  };

  krea2EnhancerNode = pkgs.fetchFromGitHub {
    owner = "capitan01R";
    repo = "ComfyUI-Krea2T-Enhancer";
    rev = "cf8895005540680306cd46e1faaf75f8902db794";
    hash = "sha256-KkUK27W/SnFhCjIV5czcm23eN8wptk1/wClv2TAJ99k=";
  };

  pixaromaNode = pkgs.fetchFromGitHub {
    owner = "pixaroma";
    repo = "ComfyUI-Pixaroma";
    rev = "c1aaee4f6a41a69563eab50e51cd1ef7347f22e9";
    hash = "sha256-cA+df6RO0z6i9urybxE9keftDhfh4o2Gxh/oSF8Blis=";
  };

  declarativeNodes = pkgs.runCommand "comfyui-declarative-custom-nodes" { } ''
    mkdir -p "$out"
    ln -s ${musePromptNode}/muse_glimmer_prompt "$out/muse_glimmer_prompt"
    ln -s ${krea2EditNode} "$out/comfyui-krea2edit"
    ln -s ${krea2EnhancerNode} "$out/ComfyUI-Krea2T-Enhancer"
    ln -s ${pixaromaNode} "$out/ComfyUI-Pixaroma"
  '';

  pixaromaEp30Archive = pkgs.fetchurl {
    url = "https://workflows.pixaroma.com/workflows/Ep30%20Workflows.zip";
    hash = "sha256-Rvy8DmMPWk7gKL3YQdBPJsqXylOMPDPSkjFZ2bH1l5k=";
  };

  eliteWorkflowManifest = pkgs.writeText "comfyui-elite-workflows.manifest" ''
    image/image_krea2_turbo_t2i.json
    image/image_krea2_turbo_t2i_int8.json
    image/image_krea2_turbo_int8_image_style_reference.json
    image/image_qwen_Image_2512.json
    image/image_qwen_image_edit_2511.json
    image/image_qwen_image_edit_2511_int8.json
    image/image_qwen_image_edit_2509_relight.json
    image/image_qwen_image_layered.json
    image/image_flux2_klein_text_to_image.json
    image/image_flux2_klein_image_edit_9b_distilled.json
    image/image_z_image_turbo_int8.json
    video/video_ltx2_3_t2v.json
    video/video_ltx2_3_i2v.json
    video/video_ltx2_3_flf2v.json
    video/video_ltx2_3_ia2v.json
    video/video_hunyuan_video_1.5_720p_t2v.json
    video/video_hunyuan_video_1.5_720p_i2v.json
    video/video_wan2_2_14B_t2v.json
    video/video_wan2_2_14B_i2v.json
    video/video_wan2_2_14B_flf2v.json
    audio/audio_ace_step_1_5_split_4b.json
    audio/audio_ace_step1_5_xl_turbo.json
    audio/audio_stable_audio_3_medium.json
    3d/3d_hunyuan3d_image_to_model.json
    3d/3d_hunyuan3d_multiview_to_model_turbo.json
    enhance/utility_seedvr2_7b_int8_upscale_image.json
    enhance/utility_seedvr2_3b_int8_upscale_video.json
    enhance/utility_interpolation_image_upscale.json
    enhance/utility-gan_upscaler.json
    cloud/api_minimax_h3_t2v.json
    cloud/api_minimax_h3_flf2v.json
    cloud/api_minimax_h3_r2v.json
    cloud/api_bytedance_seedream_5_0_pro_t2i.json
    cloud/api_bytedance_seedream_5_0_pro_image_edit.json
    cloud/api_bytedance_seedream_5_0_layer_separation.json
    cloud/api_google_nano_banana2_text_to_image.json
    cloud/api_google_nano_banana2_image_edit.json
    cloud/api_flux2.json
    cloud/api_bfl_flux_1_kontext_max_image.json
    cloud/api_runway_aleph2_video_edit.json
    cloud/api_runway_reference_to_image.json
    cloud/api_veo3.json
    cloud/api_wan2_7_t2v.json
    cloud/api_wan2_7_i2v.json
    cloud/api_wan2_7_r2v.json
    cloud/api_wan2_7_video_edit.json
    cloud/api_topaz_image_enhance_wonder3_5.json
    cloud/api_elevenlabs_text_to_dialogue.json
    cloud/api_elevenlabs_text_to_sound_effects.json
    cloud/api_elevenlabs_voice_isolation.json
    cloud/api_bytedance_seed_audio1_0_t2a.json
  '';

  eliteWorkflows = pkgs.runCommand "comfyui-elite-workflows" { nativeBuildInputs = [ pkgs.jq ]; } ''
    source_root="$(${pkgs.findutils}/bin/find ${binaryTorchPython.pkgs.comfyui-workflow-templates-json}/lib \
      -type d -path '*/comfyui_workflow_templates_json/templates' -print -quit)"
    test -n "$source_root"
    while IFS=/ read -r category filename; do
      test -n "$category" && test -n "$filename"
      source="$source_root/$filename"
      test -f "$source"
      mkdir -p "$out/$category"
      cp "$source" "$out/$category/$filename"
      jq -e . "$out/$category/$filename" >/dev/null
    done < ${eliteWorkflowManifest}
    test "$(${pkgs.findutils}/bin/find "$out" -type f -name '*.json' | wc -l)" -eq 51
  '';

  pixaromaEp30 =
    pkgs.runCommand "pixaroma-ep30-workflows"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.unzip
        ];
      }
      ''
        unzip -q ${pixaromaEp30Archive} -d unpacked
        mkdir -p "$out/workflows" "$out/media"
        cp unpacked/EP30\ Workflows/Krea2\ Edit/*.json "$out/workflows/"
        cp unpacked/EP30\ Workflows/H3\ Video\ Prompts/*.json "$out/workflows/"
        cp unpacked/EP30\ Workflows/Media\ Inputs/* "$out/media/"

        # Fail closed if the pinned archive's three known stale selectors drift.
        test "$(grep -RohF 'krea2\\krea2_turbo_int8_convrot.safetensors' "$out/workflows" | wc -l)" -eq 5
        test "$(grep -RohF 'qwen3-vl-4b-heretic_int8.safetensors' "$out/workflows" | wc -l)" -eq 10
        test "$(grep -RohF 'OutfitRock (1).jpeg' "$out/workflows" | wc -l)" -eq 1

        # Keep graph topology/settings intact while resolving the selectors
        # against this workstation's pinned model names and the ZIP's actual media.
        for workflow in "$out/workflows"/*.json; do
          substituteInPlace "$workflow" \
            --replace-warn 'krea2\\krea2_turbo_int8_convrot.safetensors' 'krea2_turbo_int8_convrot.safetensors' \
            --replace-warn 'qwen3-vl-4b-heretic_int8.safetensors' 'qwen3vl_4b_fp8_scaled.safetensors' \
            --replace-warn 'OutfitRock (1).jpeg' 'OutfitRock.jpeg'
          jq -e . "$workflow" >/dev/null
        done

        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 7
        test "$(find "$out/media" -type f | wc -l)" -eq 6
      '';

  installCreativeWorkflows = pkgs.writeShellScript "install-creative-workflows" ''
    set -eu
    user_workflows=/var/lib/comfyui/user/default/workflows
    ep30_dir="$user_workflows/pixaroma-ep30"
    elite_dir="$user_workflows/creative-suite"
    ep30_staging="$user_workflows/.pixaroma-ep30.new"
    elite_staging="$user_workflows/.creative-suite.new"
    input_dir=/var/lib/comfyui/input
    rm -rf "$ep30_staging" "$elite_staging"
    install -d -m 0700 "$ep30_staging" "$elite_staging" "$input_dir"
    for source in ${pixaromaEp30}/workflows/*.json; do
      install -m 0600 "$source" "$ep30_staging/$(basename "$source")"
    done
    for source in ${pixaromaEp30}/media/*; do
      install -m 0600 "$source" "$input_dir/$(basename "$source")"
    done
    for category in ${eliteWorkflows}/*; do
      destination="$elite_staging/$(basename "$category")"
      install -d -m 0700 "$destination"
      for source in "$category"/*.json; do
        install -m 0600 "$source" "$destination/$(basename "$source")"
      done
    done
    rm -rf "$ep30_dir" "$elite_dir"
    mv "$ep30_staging" "$ep30_dir"
    mv "$elite_staging" "$elite_dir"
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
      custom_nodes: ${declarativeNodes}
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
  ]
  ++ map (directory: "d /models/comfyui/${directory} 0750 peterstorm users - -") modelSubdirectories;

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
      # Keep physical GPU0 available for Muse Glimmer. CUDA_VISIBLE_DEVICES=1
      # makes physical GPU1 ComfyUI's only visible device, renumbered to cuda:0.
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
      ExecStartPre = [
        "${pkgs.coreutils}/bin/install -d -m 0700 /var/lib/comfyui/user"
        installCreativeWorkflows
      ];
      ExecStart = ''
        ${comfyui}/bin/comfyui \
          --listen 127.0.0.1 \
          --port 8188 \
          --disable-auto-launch \
          --base-directory /var/lib/comfyui \
          --database-url sqlite:////var/lib/comfyui/user/comfyui.db \
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
  # Core covers the native workflows; the three third-party Episode 30 packs
  # above are immutable source pins required by the imported editing workflows.
}
