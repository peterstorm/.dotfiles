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
      # ComfyUI 0.33.3's Music 3 text encoder uses APIs introduced in
      # comfy-kitchen 0.2.31. Keep all exact runtime requirements aligned with
      # the pinned ComfyUI source instead of relying on the older package set.
      comfy-kitchen = prev.comfy-kitchen.overridePythonAttrs (_old: {
        version = "0.2.31";
        src = pkgs.fetchFromGitHub {
          owner = "Comfy-Org";
          repo = "comfy-kitchen";
          rev = "7c6ca3a5b63857d42c2d49777d6afb69de23f13f";
          hash = "sha256-i7v8f+ZNhYkvheufOeJYyCZYwMj79LOt1ZNC+8tgefw=";
        };
      });
      comfyui-frontend-package = prev.comfyui-frontend-package.overridePythonAttrs (_old: {
        version = "1.49.6";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/b8/14/0d6d36fa852fe65c1a0ed983cda31fd173472a64bcdf344b73f3172cc882/comfyui_frontend_package-1.49.6.tar.gz";
          hash = "sha256-CBChUGNYpF4PHwLAaPn4ISBXmC+A1/IFmuYU563mWNk=";
        };
      });
      comfyui-workflow-templates = prev.comfyui-workflow-templates.overridePythonAttrs (_old: {
        version = "0.11.44";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/3c/34/e3f318e92f463e379455c3771b34a2327455166ddfc4804a71eff5970c1e/comfyui_workflow_templates-0.11.44.tar.gz";
          hash = "sha256-6C+qy6Wx4Wrlb0macBY4o/fgJPZ3WNs4RcA0OTm0ucQ=";
        };
      });
      comfyui-workflow-templates-json = prev.comfyui-workflow-templates-json.overridePythonAttrs (_old: {
        version = "0.1.50";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/78/eb/c1728bc38aab20294e0ba2b240cbc0740f875850a3f9b4425edbd5c982c6/comfyui_workflow_templates_json-0.1.50.tar.gz";
          hash = "sha256-C348ww+sejtpXeInN8Q7qxk81VUxbQBfHc/nmuEs9hk=";
        };
      });
      comfyui-workflow-templates-core = prev.comfyui-workflow-templates-core.overridePythonAttrs (_old: {
        version = "0.3.315";
        src = pkgs.fetchurl {
          url = "https://files.pythonhosted.org/packages/60/33/3f86ee718c21ba7f67fb23d12f8de51597fd93f281572643bbbecc4f2067/comfyui_workflow_templates_core-0.3.315.tar.gz";
          hash = "sha256-/klBIRx7cS8OiKeOQEQY+gCg6WYyj2ehwX7fZH1R7A4=";
        };
      });
      comfyui-workflow-templates-media-assets-01 =
        prev.comfyui-workflow-templates-media-assets-01.overridePythonAttrs (_old: {
          version = "0.1.30";
          src = pkgs.fetchurl {
            url = "https://files.pythonhosted.org/packages/63/48/7c276531b1274901bb9f19658118cbd53d4d44f12cad6e654fee06eae347/comfyui_workflow_templates_media_assets_01-0.1.30.tar.gz";
            hash = "sha256-5N6pN46RdJkKMVqCC/I6Zu0o7YS90V9y8pu10IryoMY=";
          };
        });
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
      color-matcher
      diffusers
      einops
      filelock
      gguf
      imageio
      imageio-ffmpeg
      kornia
      matplotlib
      mss
      numpy
      omegaconf
      opencv4
      peft
      pillow
      psutil
      pydantic
      pydantic-settings
      pyopengl
      pyyaml
      requests
      rotary-embedding-torch
      safetensors
      scenedetect
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

  # Reuse Nixpkgs' writable-runtime patch and native wrapper tool while pinning
  # the first stable ComfyUI release that contains native MiniMax Music 3.
  comfyui = pkgs.comfyui.overrideAttrs (old: {
    version = "0.33.3";
    src = pkgs.fetchFromGitHub {
      owner = "Comfy-Org";
      repo = "ComfyUI";
      rev = "4da9e2dbead52fc1e68beae33fe3d7ad63b63241";
      hash = "sha256-c3a5xBKusx3Xk26U421JrK9tqb27XTq7I9HBiNHP1/0=";
    };
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
    meta = old.meta // {
      changelog = "https://github.com/Comfy-Org/ComfyUI/releases/tag/v0.33.3";
    };
  });

  modelTools = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.hf-xet
    pythonPackages.huggingface-hub
  ]);

  modelSubdirectories = [
    "checkpoints"
    "diffusion_models"
    "text_encoders"
    "clip_vision"
    "vae"
    "loras"
    "pdd_acc"
    "controlnet"
    "upscale_models"
    "SEEDVR2"
    "audio_encoders"
  ];
  modelPathEntries = builtins.listToAttrs (
    map (directory: {
      name = directory;
      value = directory;
    }) modelSubdirectories
  );

  musePromptNode = pkgs.runCommand "comfyui-muse-glimmer-prompt" { } ''
    install -Dm444 \
      ${../../comfyui/custom_nodes/muse_glimmer_prompt/__init__.py} \
      "$out/muse_glimmer_prompt/__init__.py"
  '';

  modelPhaseRuntimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.jq
    pkgs.util-linux
  ];
  creativeModelPhase = pkgs.writeShellApplication {
    name = "creative-model-phase";
    runtimeInputs = modelPhaseRuntimeInputs;
    text = builtins.readFile ../../scripts/comfyui/creative-model-phase.sh;
  };
  h3ModelPhase = pkgs.writeShellApplication {
    name = "h3-model-phase";
    runtimeInputs = modelPhaseRuntimeInputs;
    text = ''
      export CREATIVE_MODEL_PHASE_BIN=${creativeModelPhase}/bin/creative-model-phase
      ${builtins.readFile ../../scripts/comfyui/h3-model-phase.sh}
    '';
  };
  downloadImageUpscalerModels = pkgs.writeShellApplication {
    name = "download-image-upscaler-models";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.util-linux
      modelTools
    ];
    text = builtins.readFile ../../scripts/comfyui/download-image-upscaler-models.sh;
  };
  downloadMinimaxH3FunControlnet = pkgs.writeShellApplication {
    name = "download-minimax-h3-fun-controlnet";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.util-linux
      modelTools
    ];
    text = builtins.readFile ../../scripts/comfyui/download-minimax-h3-fun-controlnet.sh;
  };

  krea2EditNode = pkgs.fetchFromGitHub {
    owner = "lbouaraba";
    repo = "comfyui-krea2edit";
    rev = "bdfa8b267fdb13730868d435b277dcfe696ec083";
    hash = "sha256-/uK+MV+x2W1Gpm3vo54154fjGcUebNRPhPByS5ms2Qk=";
  };

  krea2EnhancerSource = pkgs.fetchFromGitHub {
    owner = "capitan01R";
    repo = "ComfyUI-Krea2T-Enhancer";
    # Upstream's focused ComfyUI diffusion-wrapper ABI compatibility fix.
    rev = "a01434a0d7a77eba1899116ce2b52ffab5584e91";
    hash = "sha256-UuDjX2neQkFcGvL9V6nXSSTYfyiu9VhgmuX9/EySo5M=";
  };

  krea2EnhancerNode =
    pkgs.runCommand "comfyui-krea2t-enhancer-abi-compatible"
      {
        nativeBuildInputs = [ comfyPythonEnv ];
      }
      ''
        cp -R ${krea2EnhancerSource}/. "$out"
        chmod -R u+w "$out"
        export PYTHONPATH=${comfyui}/share/comfyui
        ${comfyPythonEnv}/bin/python - "$out" <<'PY'
        import importlib.util
        import pathlib
        import sys

        package_root = pathlib.Path(sys.argv[1])
        spec = importlib.util.spec_from_file_location(
            "krea2_enhancer_abi_contract",
            package_root / "__init__.py",
            submodule_search_locations=[str(package_root)],
        )
        if spec is None or spec.loader is None:
            raise RuntimeError("could not load the Krea enhancer module")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        class PassthroughExecutor:
            class_obj = object()

            def __call__(self, *args, **kwargs):
                return args, kwargs

        transformer_options = {
            "krea2t_prompt_adherence_enhancer": {"enabled": True}
        }
        args = (
            object(),
            object(),
            object(),
            object(),
            object(),
            transformer_options,
        )
        marker = object()
        received_args, received_kwargs = module.krea2t_enhancer_wrapper(
            PassthroughExecutor(), *args, marker=marker
        )
        assert received_args == args
        assert received_kwargs == {"marker": marker}
        PY
        chmod -R a-w "$out"
      '';

  pixaromaNode = pkgs.fetchFromGitHub {
    owner = "pixaroma";
    repo = "ComfyUI-Pixaroma";
    rev = "c1aaee4f6a41a69563eab50e51cd1ef7347f22e9";
    hash = "sha256-cA+df6RO0z6i9urybxE9keftDhfh4o2Gxh/oSF8Blis=";
  };

  detailDaemonNode = pkgs.fetchFromGitHub {
    owner = "Jonseed";
    repo = "ComfyUI-Detail-Daemon";
    rev = "3394e44afea04ed0188fb37b21f0d9952469766b";
    hash = "sha256-QmvimdfSjjE5qrm8TanSIB+U2MP4ylKCw6mArD+djUk=";
  };

  kjNodes = pkgs.fetchFromGitHub {
    owner = "kijai";
    repo = "ComfyUI-KJNodes";
    rev = "3f20054214fec9f9234fd3841ae6f1e4287948f6";
    hash = "sha256-2rurJ/wvr9zcHamGZhcTrM4D20/vMLw6xtN/+ZiHJgw=";
  };

  videoHelperSuiteNode = pkgs.fetchFromGitHub {
    owner = "Kosinkadink";
    repo = "ComfyUI-VideoHelperSuite";
    rev = "115de7a9d9e34410cffb9ecfd268e993b11a50fb";
    hash = "sha256-NgKlqrLOiCoFusVixdDPKYFs1rx4X48TxzVSObxrgl8=";
  };

  # v0.87.0 is the first revision containing every node used by the latest
  # context-window workflow. It uses one H3 audio helper added after pinned
  # ComfyUI 0.33.3; the local adapter carries that pure helper. pyproject is MIT.
  mmh3ToolsSource = pkgs.fetchFromGitHub {
    owner = "ckinpdx";
    repo = "ComfyUI-MMH3Tools";
    rev = "7194baedb1cfeb6b55d0797a3af849b73a69c6c2";
    hash = "sha256-BhZt+97AaWvSTYTJW6U4agH1N+4YzrCYYwrO9pyS35o=";
  };

  mmh3ToolsNode = pkgs.runCommand "comfyui-mmh3tools-0.87.0-compatible" { } ''
    cp -R ${mmh3ToolsSource}/. "$out"
    chmod -R u+w "$out"
    substituteInPlace "$out/mmh3tools/nodes_multiprompt.py" \
      --replace-fail '    _encode_ref_audio,' "" \
      --replace-fail \
        'MMH3CondSet = io.Custom("MMH3_COND_SET")' \
        $'try:\n    from comfy_extras.nodes_minimax_h3 import _encode_ref_audio\nexcept ImportError:\n    def _encode_ref_audio(audio_vae, audio):\n        import torchaudio\n        waveform = audio["waveform"]\n        sample_rate = audio["sample_rate"]\n        vae_sample_rate = getattr(audio_vae, "audio_sample_rate", 32000)\n        if sample_rate != vae_sample_rate:\n            waveform = torchaudio.functional.resample(waveform, sample_rate, vae_sample_rate)\n        latent = audio_vae.encode(waveform[:1].movedim(1, -1))\n        return latent, latent.shape[-1]\n\nMMH3CondSet = io.Custom("MMH3_COND_SET")'
    chmod -R a-w "$out"
  '';

  h3MotionContextSource = pkgs.fetchFromGitHub {
    owner = "seitanism";
    repo = "ComfyUI-H3-Motion-Context-MultiRef";
    rev = "87de57ba619297503fa49c9594c0c021d5b0c261";
    hash = "sha256-tu5Q7keXuZTUN8y4qSeGJqInDNm8WWwB3UQmmGWc4ek=";
  };

  # PixelEasel publishes these examples without an explicit redistribution
  # license. Fixed-output fetches keep them private to the local Development
  # build and make source drift fail closed.
  minimaxH3TwoGuideWorkflowSource = pkgs.fetchurl {
    url = "https://drive.usercontent.google.com/download?id=1YVjFwB3twS2MviP-DWSmW84gnRHzzEW-&export=download&confirm=t";
    hash = "sha256-FnuBHZDoMZfaPlg+iNc9zHI/ijdfT3aSwehRodRIojU=";
  };

  minimaxH3FourGuideWorkflowSource = pkgs.fetchurl {
    url = "https://drive.usercontent.google.com/download?id=1iSS4Dsb_tfkSAlUinHXH_w5QV1-xU3Wf&export=download&confirm=t";
    hash = "sha256-nn6Jcn7aHNgQQm1WoXr0f+PEmZrHhV2YrUopKTkNXTA=";
  };

  h3MotionContextNode =
    pkgs.runCommand "comfyui-h3-motion-context-multiref-87de57b-tested"
      {
        nativeBuildInputs = [ comfyPythonEnv ];
      }
      ''
        cp -R ${h3MotionContextSource}/. "$out"
        chmod -R u+w "$out"
        cd "$out"
        ${comfyPythonEnv}/bin/python tests/run_tests.py
        chmod -R a-w "$out"
      '';

  h3FunControlSource = pkgs.fetchFromGitHub {
    owner = "wyzborrero";
    repo = "ComfyUI-H3-FunControl";
    rev = "22a7ec38c4d16a76a8dea53b6e0faa0356f4f220";
    hash = "sha256-UIKCkqMIbWeacsycqh1ZJ0R7szuioOwyigjOKMKamYs=";
  };

  h3FunControlNode =
    pkgs.runCommand "comfyui-h3-fun-control-22a7ec3-tested"
      {
        nativeBuildInputs = [ comfyPythonEnv ];
      }
      ''
        cp -R ${h3FunControlSource}/. "$out"
        chmod -R u+w "$out"
        export PYTHONPATH=${comfyui}/share/comfyui
        ${comfyPythonEnv}/bin/python - "$out" <<'PY'
        import importlib.util
        import pathlib
        import sys
        import torch

        package_root = pathlib.Path(sys.argv[1])
        sys.argv = ["comfyui", "--cpu"]
        import comfy.options
        comfy.options.enable_args_parsing()
        spec = importlib.util.spec_from_file_location(
            "h3_fun_control_contract",
            package_root / "__init__.py",
            submodule_search_locations=[str(package_root)],
        )
        if spec is None or spec.loader is None:
            raise RuntimeError("could not load H3 Fun ControlNet")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        control = sys.modules[f"{spec.name}.control"]
        rows = control.pack_control_latent(torch.zeros((1, 24, 2, 4, 4)))
        assert tuple(rows.shape) == (8, 196)
        assert torch.count_nonzero(rows) == 0
        try:
            control.patchify(torch.zeros((2, 24, 2, 4, 4)))
        except ValueError as error:
            assert "single-batch" in str(error)
        else:
            raise AssertionError("batch > 1 must fail closed")
        PY
        chmod -R a-w "$out"
      '';

  aftersignalH3SourceEditNode =
    pkgs.runCommand "comfyui-aftersignal-h3-source-edit-tested"
      {
        nativeBuildInputs = [ comfyPythonEnv ];
      }
      ''
        cp -R ${../../comfyui/custom_nodes/aftersignal_h3_source_edit}/. "$out"
        chmod -R u+w "$out"
        ${comfyPythonEnv}/bin/python "$out/test_nodes.py"
        chmod -R a-w "$out"
      '';

  # Upstream does not declare a code license. This immutable pin is authorized
  # only for private local Development evaluation; it is not a Production or
  # redistribution grant.
  minimaxH3LatentUpscalerNode = pkgs.fetchFromGitHub {
    owner = "LBH-123-AI";
    repo = "Comfyui_Minimax_h3_latent_Upscaler";
    rev = "d7c01b9011f2e8439493f6c02c29995a27df276f";
    hash = "sha256-QIvU/ioTPw00AzoGsw3h7Y3Pbn7g9gyXWTvdhYULUHk=";
  };

  seedVR2Source = pkgs.fetchFromGitHub {
    owner = "numz";
    repo = "ComfyUI-SeedVR2_VideoUpscaler";
    rev = "4490bd1f482e026674543386bb2a4d176da245b9";
    hash = "sha256-6nsqFflLw9vYH/du35ET46fdAm1NMjjTe2bA8JmaBE4=";
  };

  seedVR2Node = pkgs.runCommand "comfyui-seedvr2-local-models-only" { } ''
    cp -R ${seedVR2Source}/. "$out"
    chmod -R u+w "$out"
    install -m 0444 \
      ${../../comfyui/custom_nodes/seedvr2_local_model_validation.py} \
      "$out/src/utils/local_model_validation.py"
    substituteInPlace "$out/src/interfaces/video_upscaler.py" \
      --replace-fail \
        'from ..utils.downloads import download_weight' \
        'from ..utils.local_model_validation import validate_installed_weight as download_weight' \
      --replace-fail \
        'Checking and downloading models if needed...' \
        'Validating immutable locally installed models...'
    if grep -RqiE 'download_with_resume|urlopen|HUGGINGFACE_BASE_URL' \
      "$out/src/interfaces" "$out/src/utils/local_model_validation.py"; then
      echo "SeedVR2 execution path retains a runtime model-download boundary" >&2
      exit 1
    fi
    chmod -R a-w "$out"
  '';

  minimaxH3DirectorSource = pkgs.fetchFromGitHub {
    owner = "AIMixer";
    repo = "ComfyUI_MiniMaxH3_Director";
    rev = "bdefc5f8037aad286ff1aa3d908dfb3cf13b080b";
    hash = "sha256-a4C72dV9K9AXWD70+LIvOTQLawTfUrRzyylM16E1J/w=";
  };

  minimaxH3TurboWorkflowSource = pkgs.fetchFromGitHub {
    owner = "ModelTC";
    repo = "Minimax-H3-Turbo";
    rev = "a7e148b8dc7db8ad976966060dcc022adf11fc8d";
    hash = "sha256-LG7fqEcWcuacQYK6DMyS7uCTnz0Wa66oO6SPRIqIENo=";
  };

  minimaxH3PddSource = pkgs.fetchFromGitHub {
    owner = "Jalen-Brunson";
    repo = "ComfyUI-MiniMax-H3-PDD-Acc";
    rev = "311a65dd53832d8a5f8177a9d5fb923c09e35a90";
    hash = "sha256-jqjqdww2pUYPOr+5ox0GtculgpL1OjKGlgALb4eN1vk=";
  };

  minimaxH3PddNode =
    pkgs.runCommand "comfyui-minimax-h3-pdd-acc-311a65d-tested"
      {
        nativeBuildInputs = [ comfyPythonEnv ];
      }
      ''
        cp -R ${minimaxH3PddSource}/. "$out"
        chmod -R u+w "$out"
        cd "$out"
        ${comfyPythonEnv}/bin/python tests/test_pdd_acc.py
        chmod -R a-w "$out"
      '';

  minimaxH3DirectorNode =
    pkgs.runCommand "comfyui-minimax-h3-director-hardened"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.python3
        ];
      }
      ''
        ${pkgs.bash}/bin/bash \
          ${../../scripts/comfyui/harden-minimax-h3-director.sh} \
          ${minimaxH3DirectorSource} "$out"
      '';

  declarativeNodes = pkgs.runCommand "comfyui-declarative-custom-nodes" { } ''
    mkdir -p "$out"
    ln -s ${musePromptNode}/muse_glimmer_prompt "$out/muse_glimmer_prompt"
    ln -s ${../../comfyui/custom_nodes/persistent_output_history} "$out/persistent_output_history"
    ln -s ${krea2EditNode} "$out/comfyui-krea2edit"
    ln -s ${krea2EnhancerNode} "$out/ComfyUI-Krea2T-Enhancer"
    ln -s ${pixaromaNode} "$out/ComfyUI-Pixaroma"
    ln -s ${detailDaemonNode} "$out/ComfyUI-Detail-Daemon"
    ln -s ${kjNodes} "$out/ComfyUI-KJNodes"
    ln -s ${videoHelperSuiteNode} "$out/ComfyUI-VideoHelperSuite"
    ln -s ${mmh3ToolsNode} "$out/ComfyUI-MMH3Tools"
    ln -s ${h3MotionContextNode} "$out/ComfyUI-H3-Motion-Context-MultiRef"
    ln -s ${h3FunControlNode} "$out/ComfyUI-H3-FunControl"
    ln -s ${aftersignalH3SourceEditNode} "$out/aftersignal_h3_source_edit"
    ln -s ${minimaxH3PddNode} "$out/ComfyUI-MiniMax-H3-PDD-Acc"
    ln -s ${minimaxH3LatentUpscalerNode} "$out/Comfyui_Minimax_h3_latent_Upscaler"
    ln -s ${seedVR2Node} "$out/ComfyUI-SeedVR2_VideoUpscaler"
    ln -s ${minimaxH3DirectorNode} "$out/ComfyUI_MiniMaxH3_Director"
  '';

  krea2AbliteratedEncoder = "huihui_qwen3vl_4b_abliterated_bf16.safetensors";

  pixaromaEp24Archive = pkgs.fetchurl {
    url = "https://workflows.pixaroma.com/workflows/Ep24%20Workflows.zip";
    hash = "sha256-aHuDeJ6dpP3bcTR1FOLyVaV+WYv99f6vT5VhUjBq8nQ=";
  };

  pixaromaEp29Archive = pkgs.fetchurl {
    url = "https://workflows.pixaroma.com/workflows/Ep29%20Workflows.zip";
    hash = "sha256-DV0WoYk/S9zdMEKOWaCfj5Uru0YDpzea6XLLTwcZWbM=";
  };

  pixaromaEp30Archive = pkgs.fetchurl {
    url = "https://workflows.pixaroma.com/workflows/Ep30%20Workflows.zip";
    hash = "sha256-Rvy8DmMPWk7gKL3YQdBPJsqXylOMPDPSkjFZ2bH1l5k=";
  };

  kreaFluxKleinWorkflowSource = pkgs.fetchurl {
    name = "krea2-flux2-klein9b-source.json";
    url = "https://drive.usercontent.google.com/download?id=1JwwwVDPAgnPdqETorb9CFDI1Vq4lVpx_&export=download&confirm=t";
    hash = "sha256-Krz3Jke8aQyFkmFkS2EwN9/HHNbCdVUZhh1lA89///I=";
  };

  pixaromaEp24ProfileNote = pkgs.writeText "pixaroma-ep24-bf16-profile-note.json" ''
    {"version":1,"content":"<h1>Pixaroma Episode 24 — workstation BF16 profile</h1><p>This graph is adapted from the pinned Episode 24 archive for this workstation's full-precision Krea 2 profile.</p><ul><li>BF16 Krea 2 Turbo diffusion model</li><li>BF16 Qwen3-VL-4B encoder</li><li>Official Qwen Image VAE</li><li>Original 8-step CFG-1 baseline; extra-pass graphs retain the original 4-step, denoise-0.4 refinement</li></ul><p>LoRA graphs use ComfyUI's core model-only LoRA loader and flat pinned model paths; no additional node package or alternate model family is required.</p>"}
  '';

  pixaromaEp24WorkflowManifest = pkgs.writeText "pixaroma-ep24-workflows.manifest" ''
    1a. Krea 2 Text to Image - Simple.json
    1b. Krea 2 Text to Image - Simple + Lora.json
    1c. Krea 2 Text to Image - Simple + Prompt Enhancer.json
    1d. Krea 2 Text to Image - Simple Low Vram.json
    2a. Krea 2 Text to Image + Extra Pass.json
    2b. Krea 2 Text to Image + Extra Pass + Lora.json
    2c. Krea 2 Text to Image + Extra Pass + Prompt Enhancer.json
    2d. Krea 2 Text to Image - 2K.json
  '';

  pixaromaEp24AbliteratedProfileNote = pkgs.writeText "pixaroma-ep24-abliterated-bf16-profile-note.json" ''
    {"version":1,"content":"<h1>Pixaroma Episode 24 — abliterated BF16 encoder profile</h1><p>This graph uses the pinned full-BF16 Huihui Qwen3-VL-4B abliterated encoder with the workstation's BF16 Krea 2 Turbo diffusion model and official Qwen Image VAE.</p><ul><li>Single-file ComfyUI BF16 encoder derived from huihui-ai/Huihui-Qwen3-VL-4B-Instruct-abliterated</li><li>Exact repository revision, byte count, and SHA-256 verified by the Krea downloader</li><li>Original Episode 24 sampler and upscale topology retained</li></ul><p>This is a lower-refusal experimental encoder profile, not a guarantee about Krea output behavior. Keep the standard BF16 workflows as the quality baseline.</p>"}
  '';

  pixaromaEp24AbliteratedWorkflowManifest = pkgs.writeText "pixaroma-ep24-abliterated-workflows.manifest" ''
    3u. Krea 2 Text to Image - 2K (Uncensored).json|3a. Krea 2 Text to Image - 2K - Abliterated BF16.json
    3u. Krea 2 Text to Image + Extra Pass + Prompt Enhancer (Uncensored).json|3b. Krea 2 Text to Image + Extra Pass + Prompt Enhancer - Abliterated BF16.json
    3u. Krea 2 Text to Image + Prompt Enhancer (Uncensored).json|3c. Krea 2 Text to Image + Prompt Enhancer - Abliterated BF16.json
  '';

  pixaromaEp29ProfileNote = pkgs.writeText "pixaroma-ep29-bf16-profile-note.json" ''
    {"version":1,"content":"<h1>Pixaroma Episode 29 — workstation BF16 profile</h1><p>This graph is adapted from the pinned Episode 29 archive for this workstation's maximum-quality local MiniMax H3 profile.</p><ul><li>Unpruned BF16 FL2VA or REF2VA — exactly one task family per graph</li><li>BF16 Qwen3-VL-32B encoder</li><li>FP16 video VAE and FP32 audio VAE</li><li>50 steps, CFG 1, no Turbo LoRA</li></ul><p>Generate one scene at a time. Do not place FL2VA and REF2VA in one active graph. The local H3 legal gate and runtime qualification in the creative-stack runbook still apply.</p>"}
  '';

  h3Fl2vaPhaseNote = pkgs.writeText "minimax-h3-fl2va-phase-note.md" ''
    ## Maximum-quality H3 — FL2VA phase

    This graph contains **only** the unpruned BF16 FL2VA family, BF16 Qwen3-VL-32B,
    the video/audio VAEs, 50 sampling steps, batch 1, and no Turbo LoRA.

    Before queueing, wait for an idle queue and run:

    ```bash
    creative-model-phase prepare h3-fl2va
    ```

    The workflow loaders then load Qwen, FL2VA, and each VAE on demand. ComfyUI
    performs the in-job phase hand-offs. Never run `/free` while this graph is active.

    After the output is saved and the queue is idle, either keep FL2VA cached for the
    next FL2VA scene or release it with:

    ```bash
    creative-model-phase release
    ```
  '';

  h3Ref2vaPhaseNote = pkgs.writeText "minimax-h3-ref2va-phase-note.md" ''
    ## Maximum-quality H3 — REF2VA phase

    This graph contains **only** the unpruned BF16 REF2VA family, BF16 Qwen3-VL-32B,
    the video/audio VAEs, 50 sampling steps, batch 1, and no Turbo LoRA.

    Before switching from FL2VA or queueing the first REF2VA scene, wait for an idle
    queue and run:

    ```bash
    creative-model-phase prepare h3-ref2va
    ```

    The workflow loaders then load Qwen, REF2VA, and each VAE on demand. ComfyUI
    performs the in-job phase hand-offs. Never run `/free` while this graph is active.

    After the output is saved and the queue is idle, either keep REF2VA cached for the
    next REF2VA scene or release it with:

    ```bash
    creative-model-phase release
    ```
  '';

  officialH3Bf16WorkflowManifest = pkgs.writeText "comfyui-official-h3-bf16-workflows.manifest" ''
    video_minimax_h3_t2v.json video_minimax_h3_bf16_t2v.json
    video_minimax_h3_i2v.json video_minimax_h3_bf16_i2v.json
    video_minimax_h3_r2v.json video_minimax_h3_bf16_r2v.json
  '';

  eliteWorkflowManifest = pkgs.writeText "comfyui-elite-workflows.manifest" ''
    image/image_krea2_turbo_t2i.json
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

  # The workflow browser follows ComfyUI's exact 0.11.44 requirement, but the
  # production-curated suite stays on the previously qualified 0.1.37 JSON
  # corpus. Newer templates silently inserted active Turbo LoRAs into H3 graphs;
  # production promotion therefore remains an explicit audited operation.
  qualifiedWorkflowTemplatesJsonSource = pkgs.fetchurl {
    url = "https://files.pythonhosted.org/packages/2e/ef/0d1dec2209f84fc5c5941ce58a1d46edfd578de06dfed158ce53a7863813/comfyui_workflow_templates_json-0.1.37.tar.gz";
    hash = "sha256-Iod2Kh8he/cSBt7l/xf+rxPpbabARESFn1Zxmgjr5Ps=";
  };
  qualifiedWorkflowTemplatesJson =
    pkgs.runCommand "qualified-comfyui-workflow-templates-json-0.1.37"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir unpacked "$out"
        tar -xzf ${qualifiedWorkflowTemplatesJsonSource} -C unpacked
        source_root="$(find unpacked -type d -path '*/comfyui_workflow_templates_json/templates' -print -quit)"
        test -n "$source_root"
        cp -R "$source_root" "$out/templates"
      '';

  eliteWorkflows =
    pkgs.runCommand "comfyui-elite-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        source_root=${qualifiedWorkflowTemplatesJson}/templates
        test -d "$source_root"
        while IFS=/ read -r category filename; do
          test -n "$category" && test -n "$filename"
          source="$source_root/$filename"
          test -f "$source"
          mkdir -p "$out/$category"
          cp "$source" "$out/$category/$filename"
          jq -e . "$out/$category/$filename" >/dev/null
        done < ${eliteWorkflowManifest}

        # Keep the official Krea T2I and style-reference topologies, but expose
        # only workstation-bound BF16 variants. The redundant INT8 T2I template is
        # intentionally absent from the curated inventory.
        krea_style_source="$out/image/image_krea2_turbo_int8_image_style_reference.json"
        krea_style_bf16="$out/image/image_krea2_turbo_bf16_image_style_reference.json"
        mv "$krea_style_source" "$krea_style_bf16"

        for krea_bf16 in \
          "$out/image/image_krea2_turbo_t2i.json" \
          "$krea_style_bf16"; do
          jq '
            walk(
              if type == "string" then
                gsub("krea2_turbo_fp8_scaled\\.safetensors"; "krea2_turbo_bf16.safetensors")
                | gsub("krea2_turbo_int8_convrot\\.safetensors"; "krea2_turbo_bf16.safetensors")
                | gsub("qwen3vl_4b_fp8_scaled\\.safetensors"; "qwen3vl_4b_bf16.safetensors")
                | gsub("https://huggingface.co/Comfy-Org/Krea-2/resolve/main/";
                    "https://huggingface.co/Comfy-Org/Krea-2/resolve/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/")
                | gsub("https://huggingface.co/Comfy-Org/Krea-2/tree/main/";
                    "https://huggingface.co/Comfy-Org/Krea-2/tree/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/")
              else . end
            )
          ' "$krea_bf16" >"$krea_bf16.new"
          mv "$krea_bf16.new" "$krea_bf16"
        done

        # Reuse the qualified official Turbo subgraph for the independently
        # pinned gokaygokay realism LoRA. Keep prompt expansion off and expose
        # only one realism adapter so stacked style drift is unrepresentable.
        krea_realism="$out/image/image_krea2_turbo_bf16_realism.json"
        jq '
          (.nodes[] | select(.id == 30)) |= (
            .title = "Krea 2 Turbo BF16 + Gokay Realism LoRA — 8 steps"
            | .widgets_values[0] = "A candid documentary portrait of a young woman waiting beside a rain-streaked station window, relaxed posture, natural skin texture, soft overcast daylight, ordinary contemporary clothing, and an unposed expression."
            | .widgets_values[1] = false
            | .widgets_values[7] = true
            | .widgets_values[8] = "krea2_realism_lora.safetensors"
            | .widgets_values[9] = 1
            | .widgets_values[10] = ""
          )
          | (.nodes[] | select(.id == 29)) |= (
              .title = "PRIMARY OUTPUT — native Krea realism"
              | .widgets_values[0] = "Krea2_Realism_BF16"
            )
          | (.nodes[] | select(.id == 47)) |= (
              .title = "Realism LoRA contract"
              | .widgets_values[0] = "## Gokay Krea 2 Realism LoRA\n\nPinned from `gokaygokay/Krea-2-Realism-LoRA@32f0436ac10e985134364e7555898c9f121a46ce`. Use one realism LoRA at a time. The author recommends Krea 2 Turbo, 8 steps, guidance 0/CFG 1, scale 1.0, and natural descriptive prompts; no trigger word is required. The local full-BF16 Turbo checkpoint replaces the video Raw-FP8-plus-Turbo-LoRA reconstruction."
            )
        ' "$out/image/image_krea2_turbo_t2i.json" >"$krea_realism"

        jq -e '
          ([.nodes[] | select(.type == "b0e5ca93-2731-42b9-8e0a-d28ea851ff81")]
            | length == 1)
          and ([.nodes[] | select(.id == 30) | .widgets_values[1]] == [false])
          and ([.nodes[] | select(.id == 30) | .widgets_values[7:11]]
            == [[true, "krea2_realism_lora.safetensors", 1, ""]])
          and ([.nodes[] | select(.id == 30) | .widgets_values[11:14]]
            == [["krea2_turbo_bf16.safetensors", "qwen3vl_4b_bf16.safetensors", "qwen_image_vae.safetensors"]])
          and ([.nodes[] | select(.id == 29) | .widgets_values[0]]
            == ["Krea2_Realism_BF16"])
        ' "$krea_realism" >/dev/null

        jq -s -e '
          length == 2
          and all(.[];
            ([.. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
              == ["krea2_turbo_bf16.safetensors"])
            and ([.. | objects | select(.type? == "CLIPLoader") | .widgets_values[0]]
              == ["qwen3vl_4b_bf16.safetensors"]))
          and ([.[0] | .. | objects | select(.type? == "KSampler") | .widgets_values[2]]
            == [8])
        ' \
          "$out/image/image_krea2_turbo_t2i.json" \
          "$krea_style_bf16" >/dev/null
        if grep -RqiE 'krea2_turbo_(int8|fp8)|qwen3vl_4b_fp8|resolve/main|tree/main' \
          "$out/image/image_krea2_turbo_t2i.json" \
          "$krea_style_bf16" \
          "$krea_realism"; then
          echo "forbidden lower-precision Krea selector or mutable link" >&2
          exit 1
        fi

        # Publish maximum-quality BF16 copies of all three compatible official
        # local H3 templates. The complete upstream Template Library remains
        # untouched; these copies are the workstation-bound user workflows.
        while read -r source_name destination_name; do
          source="$source_root/$source_name"
          destination="$out/video/$destination_name"
          test -f "$source"
          jq '
            walk(
              if type == "string" then
                if contains("## Model Links") then
                  "## Workstation full-quality H3 profile\n\nThis adapted graph uses only the pinned unpruned BF16 DiT, BF16 Qwen3-VL-32B encoder, full VAEs, 50 steps, and no Turbo LoRA. Model installation is owned by the checksum-verified local downloader."
                else
                  gsub("minimax_h3_fl2va_pruned_int8_convrot\\.safetensors";
                    "minimax_h3_fl2va_bf16.safetensors")
                  | gsub("minimax_h3_ref2va_pruned_int8_convrot\\.safetensors";
                      "minimax_h3_ref2va_bf16.safetensors")
                  | gsub("qwen3vl_32b_minimax_h3_nvfp4_awq\\.safetensors";
                      "qwen3vl_32b_minimax_h3_bf16.safetensors")
                  | gsub("https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/";
                      "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/dc559027db79c174125df4d827db55cd11178860/")
                end
              else . end
            )
            | (.. | objects | select(.type? == "BasicScheduler") | .widgets_values[1]) = 50
          ' "$source" >"$destination"
          jq -e . "$destination" >/dev/null
        done < ${officialH3Bf16WorkflowManifest}

        jq -s -e '
          length == 3
          and ([.[] | .. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
            | sort == ([
              "minimax_h3_fl2va_bf16.safetensors",
              "minimax_h3_fl2va_bf16.safetensors",
              "minimax_h3_ref2va_bf16.safetensors"
            ] | sort))
          and all(.[];
            ([.. | objects | select(.type? == "CLIPLoader") | .widgets_values[0]]
              == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
            and ([.. | objects | select(.type? == "BasicScheduler") | .widgets_values[1]]
              == [50])
            and ([.. | objects | select(.type? == "LoraLoader") ] | length == 0))
        ' "$out"/video/video_minimax_h3_bf16_*.json >/dev/null
        if grep -RqiE 'pruned_int8|nvfp4|resolve/main' \
          "$out"/video/video_minimax_h3_bf16_*.json; then
          echo "forbidden practical H3 selector or mutable link" >&2
          exit 1
        fi

        test "$(${pkgs.findutils}/bin/find "$out" -type f -name '*.json' | wc -l)" -eq 54
      '';

  h3ProductionWorkflows =
    pkgs.runCommand "minimax-h3-production-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        i2v="$out/workflows/01 MiniMax H3 BF16 FL2VA - First Frame Production.json"
        r2v="$out/workflows/02 MiniMax H3 BF16 REF2VA - Character References Production.json"

        jq --rawfile phase_note ${h3Fl2vaPhaseNote} '
          (.nodes[] | select(.id == 105)) |= (
            .title = "ON-DEMAND BF16 FL2VA — first/last-frame video"
            | .widgets_values[0] = "Use <Picture 1> as the exact opening composition. Preserve subject identity, face geometry, wardrobe, environment, and visual style. Describe one coherent action, one camera move, environmental motion, dialogue, sound effects, ambience, and music for this five-second shot."
            | .widgets_values[1] = 1344
            | .widgets_values[2] = 768
            | .widgets_values[3] = 5
          )
          | (.nodes[] | select(.id == 114)) |=
              (.title = "Picture 1 — approved first frame")
          | (.nodes[] | select(.id == 115)) |= (
              .title = "Native 768p short edge — 1344×768"
              | .widgets_values = ["16:9 (Widescreen)", 0.98, 32]
            )
          | (.nodes[] | select(.id == 117)) |= (
              .title = "SAFE MODEL PHASE — prepare FL2VA before queueing"
              | .widgets_values = [$phase_note]
            )
          | (.nodes[] | select(.id == 92)) |= (
              .title = "Save accepted FL2VA scene"
              | .widgets_values[0] = "video/H3_BF16_FL2VA_Scene"
            )
          | walk(if type == "object" then del(.properties.models) else . end)
        ' ${eliteWorkflows}/video/video_minimax_h3_bf16_i2v.json >"$i2v"

        jq --rawfile phase_note ${h3Ref2vaPhaseNote} '
          (.nodes[] | select(.id == 117)) |= (
            .title = "SAFE MODEL PHASE — prepare REF2VA before queueing"
            | .widgets_values = [$phase_note]
          )
          | (.nodes[] | select(.id == 127)) |=
              (.title = "ON-DEMAND — unpruned BF16 REF2VA only")
          | (.nodes[] | select(.id == 128)) |=
              (.title = "ON-DEMAND — BF16 Qwen3-VL-32B")
          | (.nodes[] | select(.id == 119)) |=
              (.title = "ON-DEMAND — FP16 video VAE")
          | (.nodes[] | select(.id == 120)) |=
              (.title = "ON-DEMAND — FP32 audio VAE")
          | (.nodes[] | select(.id == 115)) |= (
              .title = "Native 768p short edge — 1344×768"
              | .widgets_values = ["16:9 (Widescreen)", 0.98, 32]
            )
          | (.nodes[] | select(.id == 137)) |=
              (.title = "Picture 1 — canonical identity and face geometry")
          | (.nodes[] | select(.id == 139)) |=
              (.title = "Picture 2 — wardrobe, style, or environment role")
          | (.nodes[] | select(.id == 138)) |= (
              .title = "One scene prompt — preserve exact reference roles"
              | .widgets_values[0] = "<Picture 1>: preserve this character’s exact identity, face geometry, age, hair, and body proportions. <Picture 2>: preserve only its explicitly intended wardrobe, style, or environment role. Generate one coherent five-second scene with one primary action and one camera move. Keep continuity exact. Include deliberate dialogue, sound effects, ambience, and music instructions; add no unrequested characters, wardrobe changes, text, or watermarks."
            )
          | (.nodes[] | select(.id == 132)) |=
              (.title = "Duration — start at five seconds" | .widgets_values[0] = 5)
          | (.nodes[] | select(.id == 136)) |= (
              .title = "REF2VA conditioning — start with ref_image_size=match"
              | .widgets_values[1] = 1344
              | .widgets_values[2] = 768
              | .widgets_values[3] = 124
              | .widgets_values[4] = "match"
            )
          | (.nodes[] | select(.id == 124)) |= (
              .title = "Maximum-quality baseline — 50 steps, no Turbo"
              | .widgets_values = ["simple", 50, 1]
            )
          | (.nodes[] | select(.id == 92)) |= (
              .title = "Save accepted REF2VA scene"
              | .widgets_values[0] = "video/H3_BF16_REF2VA_Scene"
            )
          | (.groups[] | select(.title == "Models")).title =
              "On-demand BF16 load — REF2VA family only"
          | (.groups[] | select(.title == "Sampling")).title =
              "Maximum-quality 50-step sampling"
          | (.groups[] | select(.title == "User Inputs")).title =
              "Approved images and one-scene prompt"
          | walk(if type == "object" then del(.properties.models) else . end)
        ' ${eliteWorkflows}/video/video_minimax_h3_bf16_r2v.json >"$r2v"

        jq -s -e '
          length == 2
          and ([.[] | .. | objects | select(.type? == "CLIPLoader") | .widgets_values[0]]
            == [
              "qwen3vl_32b_minimax_h3_bf16.safetensors",
              "qwen3vl_32b_minimax_h3_bf16.safetensors"
            ])
          and ([.[0] | .. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
            == ["minimax_h3_fl2va_bf16.safetensors"])
          and ([.[1] | .. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
            == ["minimax_h3_ref2va_bf16.safetensors"])
          and all(.[];
            ([.. | objects | select(.type? == "BasicScheduler") | .widgets_values[1]]
              == [50])
            and ([.. | objects | select(.type? == "VAELoader") | .widgets_values[0]]
              | sort == ([
                "minimax_h3_audio_vae_fp32.safetensors",
                "minimax_h3_video_vae_fp16.safetensors"
              ] | sort))
            and ([.. | objects | select(.type? == "LoraLoader")] | length == 0)
            and ([.. | objects | select(.type? == "SaveVideo" and .mode == 0)] | length == 1))
          and ([.[0] | .. | strings | select(contains("creative-model-phase prepare h3-fl2va"))] | length == 1)
          and ([.[1] | .. | strings | select(contains("creative-model-phase prepare h3-ref2va"))] | length == 1)
        ' "$i2v" "$r2v" >/dev/null
        if grep -RqiE 'krea|pruned_int8|nvfp4|minimax_h3_turbo|resolve/main|tree/main|ComfyUI-Manager' \
          "$out/workflows"; then
          echo "forbidden Krea, practical H3, Turbo, mutable link, or Manager dependency" >&2
          exit 1
        fi
        if grep -qi 'minimax_h3_ref2va.*safetensors' "$i2v" \
          || grep -qi 'minimax_h3_fl2va.*safetensors' "$r2v"; then
          echo "H3 production workflow contains the wrong diffusion family" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 2
      '';

  pixaromaEp24 =
    pkgs.runCommand "pixaroma-ep24-krea2-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.python3
          pkgs.unzip
        ];
      }
      ''
        unzip -q ${pixaromaEp24Archive} -d unpacked
        source_root=unpacked/Ep24\ Workflows
        test "$(${pkgs.findutils}/bin/find "$source_root" -type f -name '*.json' | wc -l)" -eq 11
        test "$(${pkgs.findutils}/bin/find "$source_root" -type f -name '3u.*.json' | wc -l)" -eq 3
        mkdir -p "$out/workflows"
        profile_note="$(cat ${pixaromaEp24ProfileNote})"

        while IFS= read -r filename; do
          test -n "$filename"
          source="$source_root/$filename"
          destination="$out/workflows/$filename"
          test -f "$source"
          jq --arg profile_note "$profile_note" '
            def adapt_power_lora:
              (.nodes[] | select(.type == "Power Lora Loader (rgthree)")) as $power
              | ($power.inputs[] | select(.name == "clip") | .link) as $clip_input_link
              | ($power.outputs[] | select(.name == "CLIP") | .links[0]) as $clip_output_link
              | (.links[] | select(.[0] == $clip_input_link)) as $clip_input_edge
              | ($clip_input_edge[1]) as $clip_loader_id
              | ($clip_input_edge[2]) as $clip_loader_slot
              | (.nodes[] | select(.id == $power.id)) |= (
                  .type = "LoraLoaderModelOnly"
                  | .title = "Krea 2 Style LoRA (core)"
                  | .inputs = [
                      (.inputs[] | select(.name == "model")),
                      {"name":"lora_name","type":"COMBO","widget":{"name":"lora_name"},"link":null},
                      {"name":"strength_model","type":"FLOAT","widget":{"name":"strength_model"},"link":null}
                    ]
                  | .outputs = [(.outputs[] | select(.name == "MODEL"))]
                  | .properties = {
                      "Node name for S&R": "LoraLoaderModelOnly",
                      "cnr_id": "comfy-core",
                      "ver": "0.31.1"
                    }
                  | .widgets_values = [
                      ($power.widgets_values[2].lora | split("\\") | last),
                      $power.widgets_values[2].strength
                    ]
                  | del(.color, .bgcolor)
                )
              | (.nodes[] | select(.id == $clip_loader_id)
                  | .outputs[$clip_loader_slot].links) |=
                    map(if . == $clip_input_link then $clip_output_link else . end)
              | (.links[] | select(.[0] == $clip_output_link)) |=
                  (.[1] = $clip_loader_id | .[2] = $clip_loader_slot)
              | del(.links[] | select(.[0] == $clip_input_link));

            (.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]) =
              "krea2_turbo_bf16.safetensors"
            | (.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]) =
                "qwen3vl_4b_bf16.safetensors"
            | (.nodes[] | select(.type == "VAELoader") | .widgets_values[0]) =
                "qwen_image_vae.safetensors"
            | if any(.nodes[]; .type == "Power Lora Loader (rgthree)")
                then adapt_power_lora else . end
            | (.nodes[] | select(.type == "PixaromaNote") | .widgets_values[0]) =
                $profile_note
            | del(.extra.node_versions["rgthree-comfy"])
            | del(.extra.node_versions["ComfyUI-GGUF"])
          ' "$source" >"$destination"
          jq -e . "$destination" >/dev/null
        done < ${pixaromaEp24WorkflowManifest}

        abliterated_profile_note="$(cat ${pixaromaEp24AbliteratedProfileNote})"
        while IFS='|' read -r source_name destination_name; do
          test -n "$source_name" && test -n "$destination_name"
          source="$source_root/$source_name"
          destination="$out/workflows/$destination_name"
          test -f "$source"
          jq \
            --arg profile_note "$abliterated_profile_note" \
            --arg encoder "${krea2AbliteratedEncoder}" '
              (.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]) =
                "krea2_turbo_bf16.safetensors"
              | (.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]) =
                  $encoder
              | (.nodes[] | select(.type == "VAELoader") | .widgets_values[0]) =
                  "qwen_image_vae.safetensors"
              | (.nodes[] | select(.type == "PixaromaNote") | .widgets_values[0]) =
                  $profile_note
              | (.nodes[] | select(.type == "PixaromaLabel") | .widgets_values[0]) |=
                  gsub("Uncensored|Unrestricted"; "Abliterated BF16")
              | del(.extra.node_versions["rgthree-comfy"])
              | del(.extra.node_versions["ComfyUI-GGUF"])
            ' "$source" >"$destination"
          jq -e . "$destination" >/dev/null
        done < ${pixaromaEp24AbliteratedWorkflowManifest}

        prompt_enhancer="$out/workflows/3c. Krea 2 Text to Image + Prompt Enhancer - Abliterated BF16.json"
        prompt_enhancer_refinement="$out/workflows/3d. Krea 2 Text to Image + Prompt Enhancer + FLUX.2 Klein Realism - Abliterated BF16.json"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-krea2-composed-workflows.py} \
          --prompt-enhancer "$prompt_enhancer" \
          --realism ${kreaFluxKleinWorkflowSource} \
          --output "$prompt_enhancer_refinement"

        jq -s -e '
          length == 12
          and ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | length == 13
              and ([.[] | select(. == "krea2_turbo_bf16.safetensors")] | length == 12)
              and ([.[] | select(. == "flux-2-klein-9b-bf16.safetensors")] | length == 1))
          and ([.[] | .nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
            | length == 14
              and ([.[] | select(. == "qwen3vl_4b_bf16.safetensors")] | length == 8)
              and ([.[] | select(. == "${krea2AbliteratedEncoder}")] | length == 4)
              and ([.[] | select(. == "qwen3-vl-8b-heretic-1.3.0_bf16.safetensors")] | length == 1)
              and ([.[] | select(. == "qwen_3_8b_bf16.safetensors")] | length == 1))
          and ([.[] | .nodes[] | select(.type == "VAELoader") | .widgets_values[0]]
            | length == 13
              and ([.[] | select(. == "qwen_image_vae.safetensors")] | length == 12)
              and ([.[] | select(. == "flux2-vae.safetensors")] | length == 1))
          and ([.[] | .nodes[] | select(.type == "KSampler") | .widgets_values[2]]
            | length == 18
              and ([.[] | select(. == 8)] | length == 12)
              and ([.[] | select(. == 4)] | length == 6))
          and ([.[] | .nodes[] | select(.type == "TextGenerate")] | length == 7)
          and ([.[] | .nodes[] | select(.type == "VAEDecodeTiled")] | length == 1)
          and ([.[] | .nodes[] | select(.type == "LatentUpscaleBy")] | length == 6)
          and ([.[] | .nodes[] | select(.type == "ComfyUI-Krea2T-Enhancer")] | length == 12)
          and ([.[] | .nodes[] | select(.type == "LoraLoaderModelOnly")
              | .widgets_values[0]] | sort
            == (["krea2_kidsdrawing.safetensors", "krea2_vintagetarot.safetensors"] | sort))
          and ([.[] | .nodes[] | select(.type == "Power Lora Loader (rgthree)")]
            | length == 0)
          and all(.[]; . as $graph
            | all($graph.nodes[].inputs[]? | select(.link != null);
                .link as $link_id | any($graph.links[]; .[0] == $link_id))
            and all($graph.links[]; . as $edge
                | any($graph.nodes[]; .id == $edge[1])
                  and any($graph.nodes[]; .id == $edge[3])
                  and (($graph.nodes[] | select(.id == $edge[1])
                      | .outputs[$edge[2]].links | index($edge[0])) != null)
                  and (($graph.nodes[] | select(.id == $edge[3])
                      | .inputs[$edge[4]].link) == $edge[0]))
            and all($graph.nodes[];
                . as $node
                | all($node.outputs[]?.links[]?;
                    . as $link_id
                    | any($graph.links[]; .[0] == $link_id and .[1] == $node.id))))
          and ([.[] | .nodes[].type | select(. as $type | ([
              "CFGGuider", "CLIPLoader", "CLIPTextEncode", "ColorMatch",
              "ComfyUI-Krea2T-Enhancer", "ConditioningZeroOut",
              "EmptyFlux2LatentImage", "EmptySD3LatentImage", "Flux2Scheduler",
              "GetImageSize", "ImageScaleToTotalPixels", "ImageSharpen",
              "KSampler", "KSamplerSelect", "LatentUpscaleBy",
              "LoraLoaderModelOnly", "PixaromaLabel", "PixaromaNote",
              "PixaromaPortraitLandscape", "PixaromaPreview",
              "PixaromaResolution", "PixaromaRunTimer", "PixaromaSeed",
              "PixaromaShowText", "PreviewImage", "RandomNoise",
              "ReferenceLatent", "SamplerCustomAdvanced", "SaveImage",
              "StringConcatenate", "TextGenerate", "UNETLoader", "VAEDecode",
              "VAEDecodeTiled", "VAEEncode", "VAELoader"
            ] | index($type) | not))] | length == 0)
        ' "$out"/workflows/*.json >/dev/null
        jq -e '
          . as $workflow
          | (([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] | sort)
              == (["flux-2-klein-9b-bf16.safetensors", "krea2_turbo_bf16.safetensors"] | sort))
            and (([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] | sort)
              == ([
                "${krea2AbliteratedEncoder}",
                "qwen3-vl-8b-heretic-1.3.0_bf16.safetensors",
                "qwen_3_8b_bf16.safetensors"
              ] | sort))
            and (([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]] | sort)
              == (["flux2-vae.safetensors", "qwen_image_vae.safetensors"] | sort))
            and ([.nodes[] | select(.type == "ComfyUI-Krea2T-Enhancer")] | length == 1)
            and ([.links[] | select(.[1:5] == [218, 0, 213, 0])] | length == 1)
            and ([.links[] | select(.[1] == 218 and .[3] == 6)] | length == 0)
            and ([.nodes[] | select(.type == "ReferenceLatent")] | length == 2)
            and ([.nodes[] | select(.type == "Flux2Scheduler") | .widgets_values[0]] == [2])
            and ([.nodes[] | select(.type == "ImageScaleToTotalPixels") | .widgets_values[1]] == [4])
            and ([.nodes[] | select(.type == "SaveImage" and .mode == 0)] | length == 1)
            and any(.links[]; .[1:5] == [164, 0, 56, 0])
            and ([.groups[].title] == ["FLUX.2 Klein 9B BF16 realistic finishing stage"])
            and ([.nodes[] | select(.id == 54) | .widgets_values[0]
              | contains("Do not add, remove, redesign, or beautify anything.")] == [true])
            and all(.links[]; . as $edge
              | any($workflow.nodes[]; .id == $edge[1])
                and any($workflow.nodes[]; .id == $edge[3]))
        ' "$prompt_enhancer_refinement" >/dev/null
        if grep -RqiE 'fp8|int8|rgthree|resolve/main|tree/main|uncensored|unrestricted|krea2RealVae' \
          "$out/workflows"; then
          echo "forbidden Episode 24 model, node, or mutable link" >&2
          exit 1
        fi
        test "$(${pkgs.findutils}/bin/find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 12
      '';

  pixaromaEp29 =
    pkgs.runCommand "pixaroma-ep29-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
          pkgs.unzip
        ];
      }
      ''
        unzip -q ${pixaromaEp29Archive} -d unpacked
        source_root=unpacked/EP29\ Workflows
        mkdir -p "$out/workflows" "$out/media"
        profile_note="$(cat ${pixaromaEp29ProfileNote})"

        find "$source_root" -type f -name '*.json' \
          ! -path '*/Low Vram/*' \
          ! -path '*/4. Generate Image H3 (fl2va)/*' \
          -print0 | while IFS= read -r -d $'\0' source; do
          destination="$out/workflows/$(basename "$source")"
          jq --arg profile_note "$profile_note" '
            (.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]) |=
              if contains("fl2va") then "minimax_h3_fl2va_bf16.safetensors"
              elif contains("ref2va") then "minimax_h3_ref2va_bf16.safetensors"
              else error("unexpected Episode 29 diffusion selector")
              end
            | (.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]) =
                "qwen3vl_32b_minimax_h3_bf16.safetensors"
            | (.nodes[] | select(.type == "KSampler") | .widgets_values[2]) = 50
            | (.nodes[] | select(.type == "PixaromaNote") | .widgets_values[0]) =
                $profile_note
          ' "$source" >"$destination"
          jq -e . "$destination" >/dev/null
        done
        cp "$source_root"/Media\ Inputs/* "$out/media/"

        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 8
        test "$(find "$out/media" -type f | wc -l)" -eq 11
        jq -s -e '
          length == 8
          and ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | map(select(. == "minimax_h3_fl2va_bf16.safetensors")) | length == 4)
          and ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | map(select(. == "minimax_h3_ref2va_bf16.safetensors")) | length == 4)
          and all(.[];
            ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] as $unets
            | ($unets | length) == 1
            and ($unets[0] == "minimax_h3_fl2va_bf16.safetensors"
              or $unets[0] == "minimax_h3_ref2va_bf16.safetensors"))
            and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
              == ["qwen3vl_32b_minimax_h3_bf16.safetensors"])
            and ([.nodes[] | select(.type == "KSampler") | .widgets_values[2]] == [50])
            and (([.nodes[].type] - [
              "CLIPLoader", "ConditioningZeroOut", "KSampler",
              "MiniMaxH3ImageToVideo", "MiniMaxH3ReferenceToVideo",
              "PixaromaDuration", "PixaromaH3AudioSync", "PixaromaLabel",
              "PixaromaLoadAudio", "PixaromaLoadImageMini", "PixaromaLongestSide",
              "PixaromaNote", "PixaromaPrompt", "PixaromaRunTimer",
              "PixaromaSaveMp4", "PixaromaSizes", "UNETLoader", "VAEDecode",
              "VAEDecodeAudio", "VAELoader"
            ]) | length) == 0)
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE 'pruned_int8|nvfp4|LayerUtility' "$out/workflows"; then
          echo "forbidden Episode 29 practical selector or unsupported node" >&2
          exit 1
        fi
      '';

  pixaromaEp30 =
    pkgs.runCommand "pixaroma-ep30-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
          pkgs.python3
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
            --replace-warn 'krea2\\krea2_turbo_int8_convrot.safetensors' 'krea2_turbo_bf16.safetensors' \
            --replace-warn 'qwen3-vl-4b-heretic_int8.safetensors' 'qwen3vl_4b_bf16.safetensors' \
            --replace-warn 'krea2_turbo_fp8_scaled.safetensors' 'krea2_turbo_bf16.safetensors' \
            --replace-warn 'krea2_turbo_int8_convrot.safetensors' 'krea2_turbo_bf16.safetensors' \
            --replace-warn 'qwen3-vl-4b-heretic_int8' 'qwen3vl_4b_bf16' \
            --replace-warn '>12.2 GB<' '>24.5 GB<' \
            --replace-warn '>4.5 GB<' '>8.3 GB<' \
            --replace-warn 'OutfitRock (1).jpeg' 'OutfitRock.jpeg' \
            --replace-warn 'https://huggingface.co/Comfy-Org/Krea-2/resolve/main/' 'https://huggingface.co/Comfy-Org/Krea-2/resolve/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/' \
            --replace-warn 'https://huggingface.co/Comfy-Org/Krea-2/tree/main/' 'https://huggingface.co/Comfy-Org/Krea-2/tree/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/' \
            --replace-warn 'https://huggingface.co/DreamFast/Qwen3-VL-4b-Heretic-ComfyUI/resolve/main/' 'https://huggingface.co/Comfy-Org/Krea-2/resolve/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/text_encoders/' \
            --replace-warn 'https://huggingface.co/DreamFast/Qwen3-VL-4b-Heretic-ComfyUI/tree/main' 'https://huggingface.co/Comfy-Org/Krea-2/tree/e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96/text_encoders' \
            --replace-warn 'https://huggingface.co/conradlocke/krea2-identity-edit/resolve/main/' 'https://huggingface.co/conradlocke/krea2-identity-edit/resolve/89e9e7a09ee2e5c9331e952063d79b1b8a703280/' \
            --replace-warn 'https://huggingface.co/conradlocke/krea2-identity-edit/tree/main' 'https://huggingface.co/conradlocke/krea2-identity-edit/tree/89e9e7a09ee2e5c9331e952063d79b1b8a703280' \
            --replace-warn 'https://huggingface.co/AliveAi/Krea-2-Edit-Outfit-Transfer/resolve/main/' 'https://huggingface.co/AliveAi/Krea-2-Edit-Outfit-Transfer/resolve/827dab8588b6cb261cf9ae580c417bc068740b7f/' \
            --replace-warn 'https://huggingface.co/DreamFast/Qwen3-VL-8B-Heretic-1.3.0/resolve/main/' 'https://huggingface.co/DreamFast/Qwen3-VL-8B-Heretic-1.3.0/resolve/28dc0129b4c7c16304bc2ed3697c9437ae8ac2f3/' \
            --replace-warn 'https://huggingface.co/DreamFast/Qwen3-VL-8B-Heretic-1.3.0/tree/main/' 'https://huggingface.co/DreamFast/Qwen3-VL-8B-Heretic-1.3.0/tree/28dc0129b4c7c16304bc2ed3697c9437ae8ac2f3/' \
            --replace-warn 'https://huggingface.co/craftingmod/Qwen3-VL-8B-Heretic-INT8/resolve/main/qwen3-vl-8b-heretic-1.3.0-int8convrot.safetensors?download=true' 'https://huggingface.co/DreamFast/Qwen3-VL-8B-Heretic-1.3.0/resolve/28dc0129b4c7c16304bc2ed3697c9437ae8ac2f3/comfyui/qwen3-vl-8b-heretic-1.3.0_fp8_e4m3fn.safetensors'
          python3 ${../../scripts/comfyui/pixaroma_workflow_state.py} "$workflow"
          jq -e . "$workflow" >/dev/null
        done

        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 7
        test "$(find "$out/media" -type f | wc -l)" -eq 6
        jq -s -e '
          ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | length == 5 and all(.[]; . == "krea2_turbo_bf16.safetensors"))
          and ([.[] | .nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
            | length == 5 and all(.[]; . == "qwen3vl_4b_bf16.safetensors"))
          and all(.[]; all(.nodes[] | select(.type == "PixaromaLoraLoader");
            (.properties.loraLoaderState | fromjson) == .widgets_values[0]
            and all(.widgets_values[0].loras[]; .name | contains("\\") | not)))
        ' "$out/workflows"/*.json >/dev/null
        if grep -RqiE 'krea2_turbo_(int8|fp8)|qwen3vl_4b_fp8|qwen3-vl-4b-heretic_int8|qwen3-vl-8b-heretic-1.3.0-int8convrot|craftingmod|resolve/main|tree/main' \
          "$out/workflows"; then
          echo "forbidden Episode 30 lower-precision selector or mutable link" >&2
          exit 1
        fi
      '';

  kreaFluxKleinWorkflow =
    pkgs.runCommand "krea2-flux2-klein9b-bf16-workflow"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        source=${kreaFluxKleinWorkflowSource}
        destination="$out/workflows/Krea 2 Turbo BF16 + FLUX.2 Klein 9B BF16 - Detail Daemon.json"
        prompt="$(jq -r '.nodes[] | select(.id == 101) | .widgets_values[0]' "$source")"
        test -n "$prompt"

        jq --arg prompt "$prompt" '
          (.nodes[] | select(.id == 14) | .widgets_values[0]) =
            "krea2_turbo_bf16.safetensors"
          | (.nodes[] | select(.id == 6) | .widgets_values[0]) =
              "qwen3vl_4b_bf16.safetensors"
          | (.nodes[] | select(.id == 63) | .widgets_values[0]) =
              "flux-2-klein-9b-bf16.safetensors"
          | (.nodes[] | select(.id == 62) | .widgets_values[0]) =
              "qwen_3_8b_bf16.safetensors"
          | (.nodes[] | select(.id == 75) | .widgets_values[0]) =
              "ultra_real_krea2_v2_bf16.safetensors"
          | (.nodes[] | select(.id == 142) | .widgets_values[0]) =
              "famegrid_standard_krea2_bf16.safetensors"
          | (.nodes[] | select(.id == 5) | .widgets_values[0]) = $prompt
          | (.nodes[] | select(.id == 5) | .inputs[] | select(.name == "text") | .link) = null
          | (.nodes[] | select(.id == 96)) |= (
              .mode = 0
              | .pos = [7010, 1010]
              | .widgets_values[0] = "Krea2-Flux2-Klein-BF16"
            )
          | .nodes |= map(
              . as $node
              | select([79, 101, 121, 125, 133, 134] | index($node.id) | not)
            )
          | .links |= map(
              if .[0] == 219 then [219, 91, 0, 56, 0, "IMAGE"]
              elif .[0] == 222 then [222, 65, 0, 96, 0, "IMAGE"]
              else .
              end
            )
          | .links |= map(
              . as $link
              | select(
                  ([79, 101, 121, 125, 133, 134] | index($link[1]) | not)
                  and ([79, 101, 121, 125, 133, 134] | index($link[3]) | not)
                )
            )
          | .groups |= map(
              select(.title != "Compare" and (.title != "Face detailer" or .bounding[1] < 0))
              | if .title == "Face detailer"
                then .title = "Detail Daemon refinement"
                else .
                end
            )
          | del(.nodes[].properties.models)
        ' "$source" >"$destination"

        jq -e '
          . as $workflow
          | ([.nodes[].id] | length == (unique | length))
            and ([.links[][0]] | length == (unique | length))
            and all(.links[];
              .[1] as $source_id
              | .[3] as $destination_id
              | any($workflow.nodes[]; .id == $source_id)
                and any($workflow.nodes[]; .id == $destination_id))
          and ([.nodes[].type] | unique | sort) == ([
            "BasicScheduler", "CFGGuider", "CLIPLoader", "CLIPTextEncode",
            "ColorMatch", "ConditioningZeroOut", "DetailDaemonSamplerNode",
            "EmptyFlux2LatentImage", "EmptyLatentImage", "Flux2Scheduler",
            "GetImageSize", "ImageScaleToTotalPixels", "ImageSharpen",
            "KSamplerAdvanced", "KSamplerSelect", "LoraLoaderModelOnly",
            "ModelSamplingAuraFlow", "PreviewImage", "RandomNoise",
            "ReferenceLatent", "SamplerCustom", "SamplerCustomAdvanced",
            "SaveImage", "UNETLoader", "VAEDecode", "VAEEncode", "VAELoader"
          ] | sort)
          and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] | sort)
            == (["flux-2-klein-9b-bf16.safetensors", "krea2_turbo_bf16.safetensors"] | sort)
          and ([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] | sort)
            == (["qwen3vl_4b_bf16.safetensors", "qwen_3_8b_bf16.safetensors"] | sort)
          and ([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]] | sort)
            == (["flux2-vae.safetensors", "qwen_image_vae.safetensors"] | sort)
          and ([.nodes[] | select(.type == "LoraLoaderModelOnly") | .widgets_values[0]] | sort)
            == (["famegrid_standard_krea2_bf16.safetensors", "ultra_real_krea2_v2_bf16.safetensors"] | sort)
          and ([.nodes[] | select(.id == 6) | .widgets_values[1]] == ["krea2"])
          and ([.nodes[] | select(.id == 62) | .widgets_values[1]] == ["flux2"])
          and ([.nodes[] | select(.type == "DetailDaemonSamplerNode")] | length == 1)
          and ([.nodes[] | select(.type == "ColorMatch")] | length == 1)
          and ([.nodes[] | select(.type == "SaveImage" and .mode == 0)] | length == 1)
          and ([.groups[].title] | sort)
            == (["Detail Daemon refinement", "Krea 2", "Upscaling Via Flux Klein"] | sort)
        ' "$destination" >/dev/null
        if grep -qiE 'fp8|int8|rgthree|Rh-Comfy-Auth|resolve/main|tree/main|sam_vit|yolov8|CR Text|FaceDetailer' \
          "$destination"; then
          echo "forbidden lower-precision selector, credential, mutable link, or inactive node" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 1
      '';

  kreaSingleViewCharacterWorkflow =
    pkgs.runCommand "krea2-single-view-character-bf16-workflow"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.unzip
          pkgs.jq
          pkgs.gnugrep
        ];
      }
      ''
        set -euo pipefail
        mkdir -p unpacked "$out/workflows"
        cp ${pixaromaEp30Archive} episode30.zip
        unzip -q episode30.zip -d unpacked
        identity="unpacked/EP30 Workflows/Krea2 Edit/Krea 2 + Edit Lora - Custom Ratio.json"
        destination="$out/workflows/Krea 2 Single-View Character + Optional Realism and FLUX.2 Klein 9B BF16.json"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-krea2-composed-workflows.py} \
          --single-view "$identity" \
          --realism ${kreaFluxKleinWorkflowSource} \
          --output "$destination"
        sheet="$out/workflows/Krea 2 Three-Panel Character Sheet BF16.json"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-krea2-composed-workflows.py} \
          --three-panel "$identity" \
          --realism ${kreaFluxKleinWorkflowSource} \
          --output "$sheet"

        jq -e '
          . as $workflow
          | [
              ([.nodes[].id] | length == (unique | length)),
              ([.links[][0]] | length == (unique | length)),
              all(.links[];
                .[1] as $source_id
                | .[3] as $destination_id
                | any($workflow.nodes[]; .id == $source_id)
                  and any($workflow.nodes[]; .id == $destination_id)),
              (([.nodes[].type] | unique | sort) == ([
                "BasicScheduler", "CFGGuider", "CLIPLoader", "CLIPTextEncode",
                "ColorMatch", "ComfyUI-Krea2T-Enhancer", "ConditioningZeroOut",
                "DetailDaemonSamplerNode", "EmptyFlux2LatentImage",
                "EmptySD3LatentImage", "Flux2Scheduler", "GetImageSize",
                "ImageScaleToTotalPixels", "ImageSharpen",
                "Krea2EditGroundedEncode", "Krea2EditModelPatch", "KSamplerSelect",
                "LoraLoaderModelOnly", "PixaromaCompare", "PixaromaLabel",
                "PixaromaLoadImageMini", "PixaromaLoraLoader", "PixaromaPreview",
                "PixaromaPrompt", "PixaromaResolution", "PixaromaSliders",
                "PreviewImage", "RandomNoise", "ReferenceLatent", "SamplerCustom",
                "SamplerCustomAdvanced", "SaveImage", "UNETLoader", "VAEDecode",
                "VAEEncode", "VAELoader"
              ] | sort)),
              (([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]] | sort)
                == (["flux-2-klein-9b-bf16.safetensors", "krea2_turbo_bf16.safetensors"] | sort)),
              (([.nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]] | sort)
                == (["qwen3vl_4b_bf16.safetensors", "qwen_3_8b_bf16.safetensors"] | sort)),
              (([.nodes[] | select(.type == "VAELoader") | .widgets_values[0]] | sort)
                == (["flux2-vae.safetensors", "qwen_image_vae.safetensors"] | sort)),
              (([.nodes[] | select(.type == "LoraLoaderModelOnly")
                | { name: .widgets_values[0], mode: .mode }] | sort_by(.name))
                == ([
                  { name: "famegrid_standard_krea2_bf16.safetensors", mode: 4 },
                  { name: "ultra_real_krea2_v2_bf16.safetensors", mode: 4 }
                ] | sort_by(.name))),
              (([.nodes[] | select(.type == "PixaromaLoraLoader")
                | .widgets_values[0].loras[0]
                | { name: .name, on: .on, strength_model: .sm, strength_clip: .sc }])
                == [{
                  name: "krea2/krea2_identity_edit_v1_2.safetensors",
                  on: true,
                  strength_model: 1,
                  strength_clip: 1
                }]),
              all(.nodes[] | select(.type == "PixaromaLoraLoader");
                (.properties.loraLoaderState | fromjson) == .widgets_values[0]),
              ([.nodes[] | select(.type == "DetailDaemonSamplerNode")] | length == 1),
              (([.nodes[] | select(.type == "Krea2EditModelPatch") | .widgets_values[0]]) == [1]),
              (([.nodes[] | select(.type == "PixaromaSliders")
                | .properties.slidersState.sliders[0].value]) == [1]),
              (([.nodes[] | select(.type == "PixaromaLoadImageMini")
                | .properties.loadImagePixState | fromjson
                | { ratio: .ratio_preset, w: .fit_w, h: .fit_h }])
                == [{ ratio: "1:1", w: 1024, h: 1024 }]),
              (([.nodes[] | select(.type == "PixaromaResolution")
                | .widgets_values[0] | { ratio, w, h }])
                == [{ ratio: "1:1", w: 1024, h: 1024 }]),
              any(.links[]; .[1] == 162 and .[3] == 232),
              (([.nodes[] | select(.type == "BasicScheduler") | .widgets_values])
                == [["simple", 10, 1]]),
              (([.nodes[] | select(.type == "Flux2Scheduler") | .widgets_values[0]]) == [2]),
              (([.nodes[] | select(.type == "ImageScaleToTotalPixels") | .widgets_values[1]]) == [4]),
              ([.nodes[] | select(.type == "ReferenceLatent")] | length == 2),
              (([.nodes[] | select(.type == "PixaromaPreview")
                | { mode, prefix: .widgets_values[0], save_mode: .widgets_values[1] }])
                == [{ mode: 0, prefix: "CharacterSheet_Krea2_SingleView", save_mode: "save" }]),
              (([.nodes[] | select(.id == 46 or .id == 96) | { id, mode }] | sort_by(.id))
                == ([{ id: 46, mode: 2 }, { id: 96, mode: 2 }] | sort_by(.id))),
              any(.links[]; .[1] == 65 and .[3] == 96),
              (([.nodes[] | select(.id == 221) | .properties.promptState.text
                | contains("No front view")]) == [true]),
              (([.nodes[] | select(.id == 54) | .widgets_values[0]
                | contains("Do not photorealize")]) == [true]),
              (([.groups[].title] | sort) == ([
                "Canonical reference and BF16 Krea loaders",
                "OPTIONAL realism — both LoRAs bypassed by default",
                "Detail Daemon identity pass",
                "OPTIONAL FLUX.2 Klein 9B BF16 — outputs muted by default",
                "Identity Edit v1.2 — change one view at a time",
                "Identity QA — reject drift before approving"
              ] | sort))
            ]
          | all
        ' "$destination" >/dev/null

        jq -e '
          . as $workflow
          | [
              ([.nodes[].id] | length == (unique | length)),
              ([.links[][0]] | length == (unique | length)),
              all(.links[];
                .[1] as $source_id
                | .[3] as $destination_id
                | any($workflow.nodes[]; .id == $source_id)
                  and any($workflow.nodes[]; .id == $destination_id)),
              (([.nodes[] | select(.type == "Krea2EditGroundedEncode") | .id] | sort)
                == ([224, 228] | sort)),
              (([.nodes[] | select(.type == "SamplerCustom") | .id]) == [139]),
              (([.nodes[] | select(.id == 224 or .id == 228)
                | .widgets_values[1]]) == [1024, 1024]),
              (([.nodes[] | select(.type == "PixaromaLoadImageMini")
                | .properties.loadImagePixState | fromjson
                | { ratio: .ratio_preset, w: .fit_w, h: .fit_h }])
                == [{ ratio: "3:4", w: 768, h: 1024 }]),
              (([.nodes[] | select(.type == "PixaromaResolution")
                | .widgets_values[0] | { w, h }])
                == [{ w: 1536, h: 768 }]),
              (([.nodes[] | select(.type == "LoraLoaderModelOnly") | .mode] | unique)
                == [4]),
              (([.nodes[] | select(.type == "Krea2EditModelPatch") | .widgets_values[0]])
                == [1]),
              all(.nodes[] | select(.type == "PixaromaLoraLoader");
                (.properties.loraLoaderState | fromjson) == .widgets_values[0]),
              (([.nodes[] | select(.id == 221) | .properties.promptState.text
                | contains("THREE-PANEL CHARACTER REFERENCE SHEET")]) == [true]),
              (([.nodes[] | select(.id == 221) | .properties.promptState.text
                | contains("MAGNIFIED FACE CLOSE-UP ONLY")]) == [true]),
              (([.nodes[] | select(.id == 503)
                | { mode, prefix: .widgets_values[0] }])
                == [{ mode: 0, prefix: "CharacterSheet_Krea2_3Panel" }]),
              any(.links[]; .[1:5] == [226, 0, 224, 1]),
              any(.links[]; .[1:5] == [226, 0, 228, 1]),
              any(.links[]; .[1:5] == [226, 0, 233, 0]),
              any(.links[]; .[1:5] == [196, 0, 233, 1]),
              any(.links[]; .[1:5] == [233, 0, 232, 1]),
              any(.links[]; .[1:5] == [196, 0, 232, 4]),
              any(.links[]; .[1:5] == [226, 0, 232, 5]),
              any(.links[]; .[1] == 162 and .[3] == 232),
              any(.links[]; .[1:5] == [162, 0, 139, 5]),
              any(.links[]; .[1:5] == [164, 0, 503, 0]),
              (([.links[] | select(.[1] == 226) | .[3:5]] | sort)
                == ([[224, 1], [228, 1], [232, 5], [233, 0]] | sort)),
              (([.groups[].title] | sort) == ([
                "Approved reference — semantic and appearance identity paths",
                "Independent target latent — native three-panel generation and save",
                "Three-panel grammar and BF16 Identity Edit model"
              ] | sort))
            ]
          | all
        ' "$sheet" >/dev/null
        if grep -RqiE 'fp8|int8|rgthree|Rh-Comfy-Auth|resolve/main|tree/main|sam_vit|yolov8|CR Text|FaceDetailer|VHS_' \
          "$out/workflows"; then
          echo "forbidden lower-precision selector, credential, mutable link, or inactive dependency" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 2
      '';

  kreaMaxQualityWorkflows =
    pkgs.runCommand "krea2-max-quality-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
          pkgs.python3
          pkgs.unzip
        ];
      }
      ''
        set -euo pipefail
        mkdir -p unpacked "$out/workflows"
        cp ${pixaromaEp30Archive} episode30.zip
        unzip -q episode30.zip -d unpacked
        identity="unpacked/EP30 Workflows/Krea2 Edit/Krea 2 + Edit Lora - Custom Ratio.json"

        raw_t2i="$out/workflows/01 Krea 2 RAW BF16 - Maximum Quality Text to Image.json"
        jq '
          walk(
            if type == "string" then
              gsub("Krea-2 Turbo"; "Krea 2 RAW")
              | gsub("Krea 2 Turbo"; "Krea 2 RAW")
              | gsub("krea2_turbo_bf16\\.safetensors";
                  "krea2_raw_bf16.safetensors")
              | gsub("fast distilled text-to-image model";
                  "undistilled maximum-control text-to-image model")
            else . end
          )
          | (.. | objects | select(.type? == "UNETLoader")
              | .widgets_values[0]) = "krea2_raw_bf16.safetensors"
          | (.. | objects | select(.type? == "KSampler")
              | .widgets_values[2]) = 52
          | (.. | objects | select(.type? == "KSampler")
              | .widgets_values[3]) = 3.5
          | walk(if type == "object" then del(.properties.models) else . end)
        ' ${eliteWorkflows}/image/image_krea2_turbo_t2i.json >"$raw_t2i"

        raw_single="$out/workflows/02 Krea 2 RAW BF16 - Maximum Quality Single-View Identity.json"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-krea2-composed-workflows.py} \
          --single-view "$identity" \
          --realism ${kreaFluxKleinWorkflowSource} \
          --quality-tier raw \
          --output "$raw_single"

        raw_sheet="$out/workflows/03 Krea 2 RAW BF16 - Maximum Quality Three-Panel Identity.json"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-krea2-composed-workflows.py} \
          --three-panel "$identity" \
          --realism ${kreaFluxKleinWorkflowSource} \
          --quality-tier raw \
          --output "$raw_sheet"

        raw_klein="$out/workflows/04 Krea 2 RAW BF16 to FLUX.2 Klein 9B BF16 - Maximum Quality.json"
        jq '
          (.nodes[] | select(.id == 14) | .widgets_values[0]) =
            "krea2_raw_bf16.safetensors"
          | (.nodes[] | select(.id == 75 or .id == 142) | .mode) = 4
          | (.nodes[] | select(.id == 137)) |= (
              .title = "Krea RAW maximum-quality sampler — Euler"
              | .widgets_values = ["euler"]
            )
          | (.nodes[] | select(.id == 141)) |= (
              .title = "Krea RAW — 52 steps"
              | .widgets_values = ["simple", 52, 1]
            )
          | (.nodes[] | select(.id == 139)) |= (
              .title = "Krea RAW sampling — CFG 3.5"
              | .widgets_values[3] = 3.5
            )
          | (.nodes[] | select(.id == 96)) |= (
              .title = "Save maximum-quality RAW to Klein result"
              | .widgets_values[0] = "Krea2_RAW_BF16_Flux2_Klein9B_MaxQuality"
            )
          | (.groups[] | select(.title == "Krea 2") | .title) =
              "Krea 2 RAW BF16 — 52-step maximum quality"
          | del(.nodes[].properties.models)
        ' ${kreaFluxKleinWorkflow}/workflows/*.json >"$raw_klein"

        jq -s -e '
          length == 4
          and all(.[]; . as $graph
            | all($graph.links[]; . as $edge
              | any($graph.nodes[]; .id == $edge[1])
                and any($graph.nodes[]; .id == $edge[3])))
          and ([.[0] | .. | objects | select(.type? == "UNETLoader")
              | .widgets_values[0]] == ["krea2_raw_bf16.safetensors"])
          and ([.[0] | .. | objects | select(.type? == "KSampler")
              | .widgets_values[2:4]] == [[52, 3.5]])
          and all(.[1:3][];
            ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]
                | select(. == "krea2_raw_bf16.safetensors")]
              == ["krea2_raw_bf16.safetensors"])
            and ([.nodes[] | select(.type == "UNETLoader") | .widgets_values[0]
                | select(startswith("krea2_turbo_"))] | length == 0)
            and ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values]
              == [["simple", 20, 1]])
            and ([.nodes[] | select(.type == "SamplerCustom") | .widgets_values[3]]
              == [3])
            and ([.nodes[] | select(.type == "ComfyUI-Krea2T-Enhancer")]
              | length == 0)
            and all(.nodes[] | select(.type == "PixaromaLoraLoader");
              (.properties.loraLoaderState | fromjson) == .widgets_values[0]))
          and (([.[3].nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
              | sort) == ([
                "flux-2-klein-9b-bf16.safetensors",
                "krea2_raw_bf16.safetensors"
              ] | sort))
          and ([.[3].nodes[] | select(.type == "BasicScheduler") | .widgets_values]
              == [["simple", 52, 1]])
          and ([.[3].nodes[] | select(.type == "SamplerCustom") | .widgets_values[3]]
              == [3.5])
          and ([.[3].nodes[] | select(.type == "LoraLoaderModelOnly") | .mode]
              | unique == [4])
          and ([.[3].nodes[] | select(.type == "SaveImage" and .mode == 0)]
              | length == 1)
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE 'krea2_turbo_(bf16|fp8|int8)|ComfyUI-Krea2T-Enhancer|resolve/main|tree/main' \
          "$out/workflows"; then
          echo "forbidden Turbo diffusion, Turbo enhancer, or mutable model link in RAW workflows" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 4
      '';

  contestProductionWorkflows =
    pkgs.runCommand "contest-production-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
          pkgs.python3
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        PYTHONPATH=${../../scripts/comfyui} \
          python3 ${../../scripts/comfyui/build-contest-production-workflows.py} \
          --turbo-t2i \
            "${eliteWorkflows}/image/image_krea2_turbo_t2i.json" \
          --raw-t2i \
            "${kreaMaxQualityWorkflows}/workflows/01 Krea 2 RAW BF16 - Maximum Quality Text to Image.json" \
          --turbo-identity \
            "${kreaSingleViewCharacterWorkflow}/workflows/Krea 2 Single-View Character + Optional Realism and FLUX.2 Klein 9B BF16.json" \
          --raw-identity \
            "${kreaMaxQualityWorkflows}/workflows/02 Krea 2 RAW BF16 - Maximum Quality Single-View Identity.json" \
          --raw-sheet \
            "${kreaMaxQualityWorkflows}/workflows/03 Krea 2 RAW BF16 - Maximum Quality Three-Panel Identity.json" \
          --character-world \
            "${pixaromaEp30}/workflows/Krea 2 + Edit Lora - Character and Background.json" \
          --outfit-transfer \
            "${pixaromaEp30}/workflows/Krea 2 + Outfit Transfer 2.json" \
          --raw-klein-chain \
            "${kreaMaxQualityWorkflows}/workflows/04 Krea 2 RAW BF16 to FLUX.2 Klein 9B BF16 - Maximum Quality.json" \
          --klein-edit \
            "${eliteWorkflows}/image/image_flux2_klein_image_edit_9b_distilled.json" \
          --h3-t2v \
            "${eliteWorkflows}/video/video_minimax_h3_bf16_t2v.json" \
          --h3-fl2va \
            "${h3ProductionWorkflows}/workflows/01 MiniMax H3 BF16 FL2VA - First Frame Production.json" \
          --h3-ref2va \
            "${h3ProductionWorkflows}/workflows/02 MiniMax H3 BF16 REF2VA - Character References Production.json" \
          --output-dir "$out/workflows"

        jq -s -e '
          length == 21
          and all(.[]; . as $graph
            | ([.nodes[].id] | length == (unique | length))
            and ([.links[][0]] | length == (unique | length))
            and all($graph.links[]; . as $edge
              | any($graph.nodes[]; .id == $edge[1])
                and any($graph.nodes[]; .id == $edge[3])))
          and all((.[0:2] + .[10:13])[];
            ([.nodes[] | select(.id == 30) | .widgets_values[1]] == [false])
            and ([.nodes[] | select(.id == 30) | .widgets_values[7]] == [false]))
          and all([.[0], .[11]][];
            ([.. | objects | select(.type? == "KSampler")
              | .widgets_values[2:6]] == [[8, 1, "euler", "simple"]]))
          and all([.[1], .[10], .[12]][];
            ([.. | objects | select(.type? == "KSampler")
              | .widgets_values[2:6]] == [[52, 3.5, "euler", "simple"]]))
          and all([.[2], .[4]][];
            ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values]
              == [["simple", 10, 1]])
            and ([.nodes[] | select(.type == "SamplerCustom") | .widgets_values[3]]
              == [1]))
          and all([.[3], .[5]][];
            ([.nodes[] | select(.type == "BasicScheduler") | .widgets_values]
              == [["simple", 20, 1]])
            and ([.nodes[] | select(.type == "SamplerCustom") | .widgets_values[3]]
              == [3]))
          and all(.[2:6][];
            ([.nodes[] | select(.id == 232) | .widgets_values[0]] == [1])
            and ([.nodes[] | select(.id == 224 or .id == 228)
              | .widgets_values[1]] == [1024, 1024]))
          and all(.[7:10][];
            ([.nodes[] | select(.type == "SamplerCustom")] | length == 1)
            and ([.nodes[] | select(.id == 503 and .mode == 0)] | length == 1))
          and ([.[14].nodes[] | select(.id == 163) | .widgets_values[2:6]]
            == [[20, 3, "euler", "simple"]])
          and ([.[19].nodes[] | select(.type == "LoadImage")] | length == 2)
          and any(.[19].links[]; .[1:5] == [500, 0, 105, 1])
          and ([.[6].nodes[] | select(.type == "PixaromaLoraLoader")
            | .widgets_values[0].loras[0].name]
            == ["krea2/krea_outfittransfer.safetensors"])
          and ([.[16] | .. | objects | select(.type? == "UNETLoader")
              | .widgets_values[0]] | unique
            == ["flux-2-klein-9b-bf16.safetensors"])
          and ([.[16] | .. | objects | select(.type? == "CLIPLoader")
              | .widgets_values[0]] | unique
            == ["qwen_3_8b_bf16.safetensors"])
          and ([.[16] | .. | objects | select(.type? == "VAELoader")
              | .widgets_values[0]] | unique
            == ["flux2-vae.safetensors"])
          and all(.[17:20][];
            ([.. | objects | select(.type? == "UNETLoader") | .widgets_values[0]]
              == ["minimax_h3_fl2va_bf16.safetensors"])
            and ([.. | objects | select(.type? == "BasicScheduler") | .widgets_values]
              == [["simple", 50, 1]]))
          and ([.[20] | .. | objects | select(.type? == "UNETLoader")
              | .widgets_values[0]] == ["minimax_h3_ref2va_bf16.safetensors"])
          and ([.[20] | .. | objects | select(.type? == "BasicScheduler")
              | .widgets_values] == [["simple", 50, 1]])
          and all(.[]; all(.nodes[] | select(.type == "PixaromaLoraLoader");
            (.properties.loraLoaderState | fromjson) == .widgets_values[0]
            and all(.widgets_values[0].loras[]; .name | contains("\\") | not)))
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE \
          'krea2_turbo_(int8|fp8)|flux-2-klein-9b-fp8|qwen_3_8b_fp8|pruned_int8|nvfp4|resolve/main|tree/main|ComfyUI-Manager' \
          "$out/workflows"; then
          echo "forbidden lower-precision selector, mutable link, or dependency in contest pack" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 21
      '';

  minimaxMusic3WorkflowSource = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/Comfy-Org/workflow_templates/23de45678592886158d1d97194e26d4dc59bb5b3/templates/audio_minimax_music_3.json";
    hash = "sha256-AyIVMmWz54WWFRG3hJ9mWfRqj6foy2aXblJ5/xd0sig=";
  };

  minimaxMusic3Workflows =
    pkgs.runCommand "minimax-music3-full-quality-workflow"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        destination="$out/workflows/01 MiniMax Music 3 - Full Quality FP16 DiT + BF16 Encoder.json"
        jq \
          --arg revision "6baad88896848433857c170ba4f05d2ea9d5f218" \
          --arg encoder "minimax_music3_text_encoder_bf16.safetensors" \
          --arg phase_note $'## Local full-quality Music 3\n\nBefore queueing, run `creative-model-phase prepare music3`. This graph uses the FP16 DiT, unpruned BF16 text encoder, full DAV decoder, 30 steps, CFG 1.7, and untiled decode on the 96 GiB GPU. Queue only one GPU1 graph. After the queue is idle, either retain Music 3 for another song or run `creative-model-phase release` before Krea or H3.' \
          --arg model_note $'## Immutable local model profile\n\n- `diffusion_models/minimax_music3_dit_fp16.safetensors`\n- `text_encoders/minimax_music3_text_encoder_bf16.safetensors`\n- `vae/minimax_music3_dav.safetensors`\n\nThe downloader verifies exact byte counts and SHA-256 at Comfy-Org/MiniMax-Music-3@6baad88896848433857c170ba4f05d2ea9d5f218. The original model is governed by the MiniMax-Music3 Community License; do not infer Apache-2.0 from a repackaged repository card.' '
          def pin_model_urls($revision):
            walk(
              if type == "string"
              then gsub("Comfy-Org/MiniMax-Music-3/resolve/main";
                        "Comfy-Org/MiniMax-Music-3/resolve/" + $revision)
              else .
              end
            );
          pin_model_urls($revision)
          | (.nodes[] | select(.type == "ac99f841-a3de-4329-9564-953b81cf9e16")
              | .widgets_values[5]) = $encoder
          | (.nodes[] | select(.type == "ac99f841-a3de-4329-9564-953b81cf9e16")
              | .widgets_values[7]) = false
          | (.nodes[] | select(.type == "MarkdownNote" and .title == "Note: MiniMax Music 3")
              | .widgets_values[0]) = $phase_note
          | (.nodes[] | select(.type == "MarkdownNote" and .id == 40)
              | .widgets_values[0]) = $model_note
          | (.definitions.subgraphs[].nodes[] | select(.type == "CLIPLoader")
              | .widgets_values[0]) = $encoder
          | (.definitions.subgraphs[].nodes[] | select(.type == "CLIPLoader")
              | .properties.models[0]) = {
                name: $encoder,
                url: ("https://huggingface.co/Comfy-Org/MiniMax-Music-3/resolve/" + $revision
                  + "/text_encoders/" + $encoder),
                directory: "text_encoders"
              }
        ' ${minimaxMusic3WorkflowSource} >"$destination"

        jq -e '
          ([.nodes[] | select(.type == "ac99f841-a3de-4329-9564-953b81cf9e16")
            | .widgets_values[4:8]]
            == [[
              "minimax_music3_dit_fp16.safetensors",
              "minimax_music3_text_encoder_bf16.safetensors",
              "minimax_music3_dav.safetensors",
              false
            ]])
          and ([.definitions.subgraphs[].nodes[] | select(.type == "MiniMaxMusic3TextEncode")]
            | length == 1)
          and ([.definitions.subgraphs[].nodes[] | select(.type == "EmptyMiniMaxMusic3LatentAudio")]
            | length == 1)
          and ([.definitions.subgraphs[].nodes[] | select(.type == "KSampler")
            | .widgets_values[2:4]] == [[30, 1.7]])
        ' "$destination" >/dev/null
        if grep -qiE '(^|[^[:alnum:]_])pruned|int8|resolve/main|tree/main|ComfyUI-Manager' "$destination"; then
          echo "forbidden lower-quality selector, mutable model URL, or Manager dependency in Music 3 workflow" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 1
      '';

  minimaxH3DirectorWorkflows =
    pkgs.runCommand "minimax-h3-director-local-development-workflows"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        ${pkgs.bash}/bin/bash \
          ${../../scripts/comfyui/build-minimax-h3-director-workflows.sh} \
          --source-workflow \
            ${minimaxH3DirectorSource}/example_workflows/minimax_h3_director_r2v.json \
          --output-dir "$out/workflows"
      '';

  minimaxH3TurboLoraWorkflows =
    pkgs.runCommand "minimax-h3-turbo-lora-qualification-workflows"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        ${pkgs.bash}/bin/bash \
          ${../../scripts/comfyui/build-minimax-h3-turbo-lora-workflows.sh} \
          --i2v-source \
            ${minimaxH3TurboWorkflowSource}/example_workflows/video_minimax_h3_i2v_lightx2v_turbo.json \
          --ref2v-source \
            ${minimaxH3TurboWorkflowSource}/example_workflows/video_minimax_h3_ref2v_lightx2v_turbo.json \
          --pdd-source ${minimaxH3PddNode}/example_workflows/pdd_acc_t2v_basic.json \
          --output-dir "$out/workflows"
      '';

  minimaxH3BlenderRef2vaWorkflows =
    pkgs.runCommand "minimax-h3-blender-ref2va-local-development-workflows"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        ${pkgs.bash}/bin/bash \
          ${../../scripts/comfyui/build-minimax-h3-blender-ref2va-workflows.sh} \
          --base-source \
            ${qualifiedWorkflowTemplatesJson}/templates/video_minimax_h3_r2v.json \
          --turbo-source \
            ${minimaxH3TurboWorkflowSource}/example_workflows/video_minimax_h3_ref2v_lightx2v_turbo.json \
          --pdd-source ${minimaxH3PddNode}/example_workflows/pdd_acc_t2v_basic.json \
          --output-dir "$out/workflows"
      '';

  minimaxH3MotionContextWorkflows =
    pkgs.runCommand "minimax-h3-motion-context-local-development-workflows"
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        ${pkgs.bash}/bin/bash \
          ${../../scripts/comfyui/build-minimax-h3-motion-context-workflows.sh} \
          --source-dir ${h3MotionContextNode} \
          --two-guide-source ${minimaxH3TwoGuideWorkflowSource} \
          --four-guide-source ${minimaxH3FourGuideWorkflowSource} \
          --output-dir "$out/workflows"
      '';

  imageUpscalerWorkflows =
    pkgs.runCommand "image-upscaler-qualification-v1-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        interpolation=${qualifiedWorkflowTemplatesJson}/templates/utility_interpolation_image_upscale.json
        gan=${qualifiedWorkflowTemplatesJson}/templates/utility-gan_upscaler.json
        video=${seedVR2Node}/example_workflows/SeedVR2_HD_video_upscale.json

        lanczos="$out/workflows/00 Lanczos 4x - Zero Hallucination Control.json"
        jq '
          .nodes |= map(select(.id != 7 and .id != 8))
          | .links |= map(select(.[0] != 5 and .[0] != 6))
          | (.nodes[] | select(.id == 2) | .widgets_values[0]) =
              "upscaler-qualification.png"
          | (.nodes[] | select(.id == 2) | .outputs[0].links) = [2]
          | (.nodes[] | select(.id == 3)) |= (
              .title = "Lanczos 4x — exact interpolation control"
              | .widgets_values = ["lanczos", 4]
              | .outputs[0].links = [4]
            )
          | (.nodes[] | select(.id == 5) | .widgets_values[0]) =
              "UpscalerQualification/Lanczos4x"
        ' "$interpolation" >"$lanczos"

        for specification in \
          "RealESRGAN_x4plus.pth|01 Real-ESRGAN x4plus - Learned Fidelity.json|UpscalerQualification/RealESRGAN_x4plus" \
          "realesr-general-x4v3.pth|02 Real-ESRGAN General x4v3 - Compact Fidelity.json|UpscalerQualification/RealESRGAN_General_x4v3"; do
          IFS='|' read -r model filename prefix <<<"$specification"
          destination="$out/workflows/$filename"
          jq --slurpfile gan "$gan" --arg model "$model" --arg prefix "$prefix" '
            .nodes |= map(select(.id != 7 and .id != 8))
            | .links |= map(select(.[0] != 5 and .[0] != 6))
            | (.nodes[] | select(.id == 2) | .widgets_values[0]) =
                "upscaler-qualification.png"
            | (.nodes[] | select(.id == 2) | .outputs[0].links) = [2]
            | (.nodes[] | select(.id == 3)) |= (
                .type = "ImageUpscaleWithModel"
                | .title = "Learned 4x fidelity candidate"
                | .inputs = [
                    {"name":"upscale_model","type":"UPSCALE_MODEL","link":7},
                    {"name":"image","type":"IMAGE","link":2}
                  ]
                | .properties = {"Node name for S&R":"ImageUpscaleWithModel"}
                | .widgets_values = []
                | .outputs[0].links = [4]
              )
            | ($gan[0].nodes[] | select(.type == "UpscaleModelLoader")) as $loader
            | .nodes += [$loader | .id = 9 | .pos = [80, 420]
                | .widgets_values[0] = $model | .outputs[0].links = [7]
                | del(.properties.models)]
            | .links += [[7,9,0,3,0,"UPSCALE_MODEL"]]
            | .last_node_id = 9
            | .last_link_id = 7
            | (.nodes[] | select(.id == 5) | .widgets_values[0]) = $prefix
          ' "$interpolation" >"$destination"
        done

        for specification in \
          "seedvr2_ema_3b_fp16.safetensors|03 SeedVR2 3B FP16 - Natural 4K.json|UpscalerQualification/SeedVR2_3B_FP16" \
          "seedvr2_ema_7b_fp16.safetensors|04 SeedVR2 7B FP16 - Natural 4K.json|UpscalerQualification/SeedVR2_7B_FP16" \
          "seedvr2_ema_7b_sharp_fp16.safetensors|05 SeedVR2 7B FP16 Sharp - Adversarial Comparison.json|UpscalerQualification/SeedVR2_7B_Sharp_FP16"; do
          IFS='|' read -r model filename prefix <<<"$specification"
          destination="$out/workflows/$filename"
          jq --arg model "$model" --arg prefix "$prefix" '
            .nodes |= map(select(.id != 18 and .id != 19 and .id != 20))
            | .links |= map(select(.[0] != 18 and .[0] != 19))
            | (.nodes[] | select(.id == 14) | .inputs[]
                | select(.name == "torch_compile_args") | .link) = null
            | (.nodes[] | select(.id == 13) | .inputs[]
                | select(.name == "torch_compile_args") | .link) = null
            | (.nodes[] | select(.id == 14)) |= (
                .title = "Immutable FP16 SeedVR2 DiT — no auto-download"
                | .widgets_values = [$model, "cuda:0", 0, false, "none", false, "sdpa"]
              )
            | (.nodes[] | select(.id == 13)) |= (
                .title = "Immutable FP16 SeedVR2 VAE — untiled on 96 GiB"
                | .widgets_values = [
                    "ema_vae_fp16.safetensors", "cuda:0",
                    false, 1024, 128, false, 1024, 128, "false", "none", false
                  ]
              )
            | (.nodes[] | select(.id == 10)) |= (
                .title = "Deterministic still-image restoration — LAB color lock"
                | .widgets_values = [
                    42, "fixed", 4096, 4096, 1, false, "lab",
                    0, 0, 0, 0, "none", true
                  ]
              )
            | (.nodes[] | select(.id == 16) | .widgets_values[0]) =
                "upscaler-qualification.png"
            | (.nodes[] | select(.id == 15) | .widgets_values[0]) = $prefix
          ' ${seedVR2Node}/example_workflows/SeedVR2_simple_image_upscale.json >"$destination"
        done

        video_destination="$out/workflows/06 SeedVR2 7B FP16 - Natural Video 2K.json"
        jq '
          .nodes |= map(select(.id != 18 and .id != 19 and .id != 20))
          | .links |= map(select(.[0] != 18 and .[0] != 19))
          | (.nodes[] | select(.id == 14) | .inputs[]
              | select(.name == "torch_compile_args") | .link) = null
          | (.nodes[] | select(.id == 13) | .inputs[]
              | select(.name == "torch_compile_args") | .link) = null
          | (.nodes[] | select(.id == 14)) |= (
              .title = "Immutable FP16 SeedVR2 7B natural — no auto-download"
              | .widgets_values = [
                  "seedvr2_ema_7b_fp16.safetensors", "cuda:0",
                  0, false, "none", false, "sdpa"
                ]
            )
          | (.nodes[] | select(.id == 13)) |= (
              .title = "Immutable FP16 SeedVR2 VAE — tiled video finishing"
              | .widgets_values = [
                  "ema_vae_fp16.safetensors", "cuda:0",
                  true, 1024, 128, true, 1024, 128, "false", "cpu", false
                ]
            )
          | (.nodes[] | select(.id == 10)) |= (
              .title = "Deterministic temporal restoration — LAB color lock"
              | .widgets_values = [
                  42, "fixed", 1536, 2688, 9, true, "lab",
                  2, 0, 0, 0, "cpu", true
                ]
            )
          | (.nodes[] | select(.id == 21) | .widgets_values[0]) =
              "upscaler-qualification.mp4"
          | (.nodes[] | select(.id == 23) | .widgets_values[0]) =
              "UpscalerQualification/SeedVR2_7B_FP16_Natural_Video_2K"
        ' "$video" >"$video_destination"

        jq -s -e '
          length == 7
          and ([.[0].nodes[] | select(.type == "ImageScaleBy") | .widgets_values]
            == [["lanczos",4]])
          and all(.[1:3][];
            ([.nodes[] | select(.type == "UpscaleModelLoader")] | length == 1)
            and ([.nodes[] | select(.type == "ImageUpscaleWithModel")] | length == 1))
          and ([.[3:6][] | .nodes[] | select(.type == "SeedVR2LoadDiTModel")
            | .widgets_values[0]] | sort) == ([
              "seedvr2_ema_3b_fp16.safetensors",
              "seedvr2_ema_7b_fp16.safetensors",
              "seedvr2_ema_7b_sharp_fp16.safetensors"
            ] | sort)
          and all(.[3:6][];
            ([.nodes[] | select(.type == "SeedVR2LoadVAEModel")
              | .widgets_values[0]] == ["ema_vae_fp16.safetensors"])
            and ([.nodes[] | select(.type == "SeedVR2VideoUpscaler")
              | .widgets_values[0:13]] == [[
                42, "fixed", 4096, 4096, 1, false, "lab",
                0, 0, 0, 0, "none", true
              ]]))
          and ([.[6].nodes[] | select(.type == "SeedVR2LoadDiTModel")
            | .widgets_values] == [[
              "seedvr2_ema_7b_fp16.safetensors", "cuda:0",
              0, false, "none", false, "sdpa"
            ]])
          and ([.[6].nodes[] | select(.type == "SeedVR2LoadVAEModel")
            | .widgets_values] == [[
              "ema_vae_fp16.safetensors", "cuda:0",
              true, 1024, 128, true, 1024, 128, "false", "cpu", false
            ]])
          and ([.[6].nodes[] | select(.type == "SeedVR2VideoUpscaler")
            | .widgets_values[0:13]] == [[
              42, "fixed", 1536, 2688, 9, true, "lab",
              2, 0, 0, 0, "cpu", true
            ]])
          and all(.[3:7][]; ([.nodes[] | select(.type == "Note")] | length) == 0)
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE 'fp8|int8|resolve/main|tree/main|ComfyUI-Manager' "$out/workflows"; then
          echo "forbidden lower-precision selector, mutable link, or Manager dependency in upscaler qualification" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 7
      '';

  h3SafeUpscalerWorkflows =
    pkgs.runCommand "minimax-h3-safe-upscaler-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
        set -euo pipefail
        mkdir -p "$out/workflows"
        source="${imageUpscalerWorkflows}/workflows/06 SeedVR2 7B FP16 - Natural Video 2K.json"

        lanczos="$out/workflows/00 MiniMax H3 Output - Lanczos 2x Zero Hallucination Video.json"
        jq '
          .nodes |= map(select(.id != 13 and .id != 14 and .id != 17))
          | .last_node_id = 24
          | .last_link_id = 25
          | .links = [
              [20,21,0,22,0,"VIDEO"],
              [21,22,0,10,0,"IMAGE"],
              [22,10,0,24,0,"IMAGE"],
              [23,24,0,23,0,"VIDEO"],
              [24,22,2,24,2,"FLOAT"],
              [25,22,1,24,1,"AUDIO"]
            ]
          | (.nodes[] | select(.id == 21)) |= (
              .order = 0
              | .title = "INPUT — native H3 video master; select your file"
              | .widgets_values[0] = "h3-native-master.mp4"
            )
          | (.nodes[] | select(.id == 22)) |= (
              .order = 1
              | .outputs[0].links = [21]
              | .outputs[1].links = [25]
              | .outputs[2].links = [24]
            )
          | (.nodes[] | select(.id == 10)) |= (
              .type = "ImageScaleBy"
              | .pos = [700, 100]
              | .size = [300, 102]
              | .order = 2
              | .title = "Faithful 2x interpolation — no invented detail"
              | .inputs = [{"name":"image","type":"IMAGE","link":21}]
              | .outputs = [{"name":"IMAGE","type":"IMAGE","links":[22]}]
              | .properties = {
                  "Node name for S&R":"ImageScaleBy",
                  "cnr_id":"comfy-core",
                  "ver":"0.3.68"
                }
              | .widgets_values = ["lanczos", 2]
              | .widgets_values_named = {
                  "upscale_method":"lanczos",
                  "scale_by":2
                }
            )
          | (.nodes[] | select(.id == 24)) |= (
              .order = 3
              | .title = "Preview audio only — remux authoritative dialogue after finishing"
              | .inputs[0].link = 22
              | .inputs[1].link = 25
              | .inputs[2].link = 24
            )
          | (.nodes[] | select(.id == 23)) |= (
              .order = 4
              | .title = "SAVE — faithful H3 finishing derivative"
              | .inputs[0].link = 23
              | .widgets_values[0] =
                  "H3_Finishing_Derivative/Lanczos2x_Zero_Hallucination"
            )
        ' "$source" >"$lanczos"

        for specification in \
          "RealESRGAN_x4plus.pth|01 MiniMax H3 Output - Real-ESRGAN x4plus to 2x Video.json|RealESRGAN_x4plus_to2x" \
          "realesr-general-x4v3.pth|02 MiniMax H3 Output - Real-ESRGAN General x4v3 to 2x Video.json|RealESRGAN_General_x4v3_to2x"; do
          IFS='|' read -r model filename slug <<<"$specification"
          destination="$out/workflows/$filename"
          jq --arg model "$model" --arg slug "$slug" '
            .nodes |= map(select(.id != 17))
            | .last_node_id = 24
            | .last_link_id = 26
            | .links = [
                [11,14,0,10,0,"UPSCALE_MODEL"],
                [20,21,0,22,0,"VIDEO"],
                [21,22,0,10,1,"IMAGE"],
                [22,10,0,13,0,"IMAGE"],
                [23,13,0,24,0,"IMAGE"],
                [24,24,0,23,0,"VIDEO"],
                [25,22,2,24,2,"FLOAT"],
                [26,22,1,24,1,"AUDIO"]
              ]
            | (.nodes[] | select(.id == 14)) |= (
                .type = "UpscaleModelLoader"
                | .pos = [420, 380]
                | .size = [300, 82]
                | .order = 0
                | .title = "Pinned BSD-3-Clause Real-ESRGAN model"
                | .inputs = []
                | .outputs = [{"name":"UPSCALE_MODEL","type":"UPSCALE_MODEL","links":[11]}]
                | .properties = {
                    "Node name for S&R":"UpscaleModelLoader",
                    "cnr_id":"comfy-core",
                    "ver":"0.3.68"
                  }
                | .widgets_values = [$model]
                | .widgets_values_named = {"model_name":$model}
              )
            | (.nodes[] | select(.id == 21)) |= (
                .order = 1
                | .title = "INPUT — native H3 video master; select your file"
                | .widgets_values[0] = "h3-native-master.mp4"
              )
            | (.nodes[] | select(.id == 22)) |= (
                .order = 2
                | .outputs[0].links = [21]
                | .outputs[1].links = [26]
                | .outputs[2].links = [25]
              )
            | (.nodes[] | select(.id == 10)) |= (
                .type = "ImageUpscaleWithModel"
                | .pos = [760, 100]
                | .size = [300, 102]
                | .order = 3
                | .title = "Framewise 4x learned upscale — inspect temporal shimmer"
                | .inputs = [
                    {"name":"upscale_model","type":"UPSCALE_MODEL","link":11},
                    {"name":"image","type":"IMAGE","link":21}
                  ]
                | .outputs = [{"name":"IMAGE","type":"IMAGE","links":[22]}]
                | .properties = {
                    "Node name for S&R":"ImageUpscaleWithModel",
                    "cnr_id":"comfy-core",
                    "ver":"0.3.68"
                  }
                | .widgets_values = []
                | del(.widgets_values_named)
              )
            | (.nodes[] | select(.id == 13)) |= (
                .type = "ImageScaleBy"
                | .pos = [1110, 100]
                | .size = [300, 102]
                | .order = 4
                | .title = "Lanczos downsample 4x result to matched 2x delivery"
                | .inputs = [{"name":"image","type":"IMAGE","link":22}]
                | .outputs = [{"name":"IMAGE","type":"IMAGE","links":[23]}]
                | .properties = {
                    "Node name for S&R":"ImageScaleBy",
                    "cnr_id":"comfy-core",
                    "ver":"0.3.68"
                  }
                | .widgets_values = ["lanczos", 0.5]
                | .widgets_values_named = {
                    "upscale_method":"lanczos",
                    "scale_by":0.5
                  }
              )
            | (.nodes[] | select(.id == 24)) |= (
                .order = 5
                | .title = "Preview audio only — remux authoritative dialogue after finishing"
                | .inputs[0].link = 23
                | .inputs[1].link = 26
                | .inputs[2].link = 25
                | .outputs[0].links = [24]
              )
            | (.nodes[] | select(.id == 23)) |= (
                .order = 6
                | .title = "SAVE — learned framewise H3 finishing derivative"
                | .inputs[0].link = 24
                | .widgets_values[0] =
                    ("H3_Finishing_Derivative/" + $slug)
              )
          ' "$source" >"$destination"
        done

        seedvr="$out/workflows/03 MiniMax H3 Output - SeedVR2 7B FP16 Natural Video 2K.json"
        jq '
          (.nodes[] | select(.id == 21)) |= (
            .title = "INPUT — native H3 video master; select your file"
            | .widgets_values[0] = "h3-native-master.mp4"
          )
          | (.nodes[] | select(.id == 14) | .title) =
              "RUN creative-model-phase prepare upscale — SeedVR2 7B FP16"
          | (.nodes[] | select(.id == 10) | .title) =
              "Generative H3 restoration derivative — inspect invented texture and edge halos"
          | (.nodes[] | select(.id == 24) | .title) =
              "Preview audio only — remux authoritative dialogue after finishing"
          | (.nodes[] | select(.id == 23)) |= (
              .title = "SAVE — generative H3 finishing derivative"
              | .widgets_values[0] =
                  "H3_Finishing_Derivative/SeedVR2_7B_FP16_Natural_Video_2K"
          )
        ' "$source" >"$seedvr"

        jq -s -e '
          length == 4
          and ([.[0].nodes[] | select(.type == "ImageScaleBy")
            | .widgets_values] == [["lanczos",2]])
          and ([.[0].nodes[] | select(.type == "UpscaleModelLoader"
            or .type == "ImageUpscaleWithModel"
            or (.type | startswith("SeedVR2")))] | length) == 0
          and ([.[1:3][] | .nodes[] | select(.type == "UpscaleModelLoader")
            | .widgets_values[0]] == [
              "RealESRGAN_x4plus.pth",
              "realesr-general-x4v3.pth"
            ])
          and all(.[1:3][];
            ([.nodes[] | select(.type == "ImageUpscaleWithModel")] | length) == 1
            and ([.nodes[] | select(.type == "ImageScaleBy")
              | .widgets_values] == [["lanczos",0.5]])
            and ([.nodes[] | select(.type == "CreateVideo")
              | .outputs[0].links] == [[24]])
            and ([.nodes[] | select(.type | startswith("SeedVR2"))] | length) == 0)
          and ([.[3].nodes[] | select(.type == "SeedVR2LoadDiTModel")
            | .widgets_values[0]] == ["seedvr2_ema_7b_fp16.safetensors"])
          and ([.[3].nodes[] | select(.type == "SeedVR2LoadVAEModel")
            | .widgets_values[0]] == ["ema_vae_fp16.safetensors"])
          and ([.[3].nodes[] | select(.type == "SeedVR2VideoUpscaler")
            | .widgets_values[0:13]] == [[
              42, "fixed", 1536, 2688, 9, true, "lab",
              2, 0, 0, 0, "cpu", true
            ]])
          and all(.[].nodes[] | select(.type == "SaveVideo"); .mode == 0)
          and all(.[].nodes[] | select(.type == "LoadVideo");
            .widgets_values[0] == "h3-native-master.mp4")
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE 'MinimaxH3LatentUpscaler|MMH3|pruned_int8|nvfp4|resolve/main|tree/main' \
          "$out/workflows"; then
          echo "forbidden blocked latent upscaler, quantized selector, or mutable link" >&2
          exit 1
        fi
        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 4
      '';

  installCreativeWorkflows = pkgs.writeShellScript "install-creative-workflows" ''
    set -eu
    user_workflows=/var/lib/comfyui/user/default/workflows
    ep24_dir="$user_workflows/pixaroma-ep24-krea2-bf16"
    ep29_dir="$user_workflows/pixaroma-ep29-h3-bf16"
    ep30_dir="$user_workflows/pixaroma-ep30"
    klein_dir="$user_workflows/krea2-flux2-klein9b-bf16"
    character_dir="$user_workflows/krea2-character-sheet-bf16"
    krea_max_dir="$user_workflows/krea2-max-quality-bf16"
    contest_dir="$user_workflows/contest-production-bf16"
    h3_production_dir="$user_workflows/minimax-h3-production-bf16"
    music3_dir="$user_workflows/minimax-music3-full-quality"
    upscaler_dir="$user_workflows/image-upscaler-qualification-v1"
    h3_safe_upscaler_dir="$user_workflows/minimax-h3-upscaler-local-safe"
    blocked_h3_upscaler_dir="$user_workflows/minimax-h3-upscaler-research-only"
    director_dir="$user_workflows/minimax-h3-director-local-development"
    h3_turbo_dir="$user_workflows/minimax-h3-turbo-lora-qualification"
    h3_blender_dir="$user_workflows/minimax-h3-blender-ref2va-development"
    h3_motion_context_dir="$user_workflows/minimax-h3-motion-context-development"
    elite_dir="$user_workflows/creative-suite"
    ep24_staging="$user_workflows/.pixaroma-ep24-krea2-bf16.new"
    ep29_staging="$user_workflows/.pixaroma-ep29-h3-bf16.new"
    ep30_staging="$user_workflows/.pixaroma-ep30.new"
    klein_staging="$user_workflows/.krea2-flux2-klein9b-bf16.new"
    character_staging="$user_workflows/.krea2-character-sheet-bf16.new"
    krea_max_staging="$user_workflows/.krea2-max-quality-bf16.new"
    contest_staging="$user_workflows/.contest-production-bf16.new"
    h3_production_staging="$user_workflows/.minimax-h3-production-bf16.new"
    music3_staging="$user_workflows/.minimax-music3-full-quality.new"
    upscaler_staging="$user_workflows/.image-upscaler-qualification-v1.new"
    h3_safe_upscaler_staging="$user_workflows/.minimax-h3-upscaler-local-safe.new"
    director_staging="$user_workflows/.minimax-h3-director-local-development.new"
    h3_turbo_staging="$user_workflows/.minimax-h3-turbo-lora-qualification.new"
    h3_blender_staging="$user_workflows/.minimax-h3-blender-ref2va-development.new"
    h3_motion_context_staging="$user_workflows/.minimax-h3-motion-context-development.new"
    elite_staging="$user_workflows/.creative-suite.new"
    input_dir=/var/lib/comfyui/input
    blender_input_dir="$input_dir/h3-blender-previz"
    rm -rf \
      "$ep24_staging" "$ep29_staging" "$ep30_staging" "$klein_staging" \
      "$character_staging" "$krea_max_staging" "$contest_staging" \
      "$h3_production_staging" "$music3_staging" "$upscaler_staging" \
      "$h3_safe_upscaler_staging" "$director_staging" "$h3_turbo_staging" \
      "$h3_blender_staging" "$h3_motion_context_staging" "$elite_staging"
    install -d -m 0700 \
      "$ep24_staging" "$ep29_staging" "$ep30_staging" "$klein_staging" \
      "$character_staging" "$krea_max_staging" "$contest_staging" \
      "$h3_production_staging" "$music3_staging" "$upscaler_staging" \
      "$h3_safe_upscaler_staging" "$director_staging" "$h3_turbo_staging" \
      "$h3_blender_staging" "$h3_motion_context_staging" "$elite_staging" \
      "$input_dir" "$blender_input_dir"
    for source in ${pixaromaEp24}/workflows/*.json; do
      install -m 0600 "$source" "$ep24_staging/$(basename "$source")"
    done
    for source in ${pixaromaEp29}/workflows/*.json; do
      install -m 0600 "$source" "$ep29_staging/$(basename "$source")"
    done
    for source in ${pixaromaEp29}/media/*; do
      install -m 0600 "$source" "$input_dir/$(basename "$source")"
    done
    for source in ${pixaromaEp30}/workflows/*.json; do
      install -m 0600 "$source" "$ep30_staging/$(basename "$source")"
    done
    for source in ${pixaromaEp30}/media/*; do
      install -m 0600 "$source" "$input_dir/$(basename "$source")"
    done
    for source in ${kreaFluxKleinWorkflow}/workflows/*.json; do
      install -m 0600 "$source" "$klein_staging/$(basename "$source")"
    done
    for source in ${kreaSingleViewCharacterWorkflow}/workflows/*.json; do
      install -m 0600 "$source" "$character_staging/$(basename "$source")"
    done
    for source in ${kreaMaxQualityWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$krea_max_staging/$(basename "$source")"
    done
    for source in ${contestProductionWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$contest_staging/$(basename "$source")"
    done
    for source in ${h3ProductionWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$h3_production_staging/$(basename "$source")"
    done
    for source in ${minimaxMusic3Workflows}/workflows/*.json; do
      install -m 0600 "$source" "$music3_staging/$(basename "$source")"
    done
    for source in ${imageUpscalerWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$upscaler_staging/$(basename "$source")"
    done
    for source in ${h3SafeUpscalerWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$h3_safe_upscaler_staging/$(basename "$source")"
    done
    for source in ${minimaxH3DirectorWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$director_staging/$(basename "$source")"
    done
    for source in ${minimaxH3TurboLoraWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$h3_turbo_staging/$(basename "$source")"
    done
    for source in ${minimaxH3BlenderRef2vaWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$h3_blender_staging/$(basename "$source")"
    done
    for source in ${minimaxH3MotionContextWorkflows}/workflows/*.json; do
      install -m 0600 "$source" "$h3_motion_context_staging/$(basename "$source")"
    done
    for category in ${eliteWorkflows}/*; do
      destination="$elite_staging/$(basename "$category")"
      install -d -m 0700 "$destination"
      for source in "$category"/*.json; do
        install -m 0600 "$source" "$destination/$(basename "$source")"
      done
    done
    rm -rf \
      "$ep24_dir" "$ep29_dir" "$ep30_dir" "$klein_dir" "$character_dir" \
      "$krea_max_dir" "$contest_dir" "$h3_production_dir" "$music3_dir" \
      "$upscaler_dir" "$h3_safe_upscaler_dir" "$blocked_h3_upscaler_dir" \
      "$director_dir" "$h3_turbo_dir" "$h3_blender_dir" \
      "$h3_motion_context_dir" "$elite_dir"
    mv "$ep24_staging" "$ep24_dir"
    mv "$ep29_staging" "$ep29_dir"
    mv "$ep30_staging" "$ep30_dir"
    mv "$klein_staging" "$klein_dir"
    mv "$character_staging" "$character_dir"
    mv "$krea_max_staging" "$krea_max_dir"
    mv "$contest_staging" "$contest_dir"
    mv "$h3_production_staging" "$h3_production_dir"
    mv "$music3_staging" "$music3_dir"
    mv "$upscaler_staging" "$upscaler_dir"
    mv "$h3_safe_upscaler_staging" "$h3_safe_upscaler_dir"
    mv "$director_staging" "$director_dir"
    mv "$h3_turbo_staging" "$h3_turbo_dir"
    mv "$h3_blender_staging" "$h3_blender_dir"
    mv "$h3_motion_context_staging" "$h3_motion_context_dir"
    mv "$elite_staging" "$elite_dir"
  '';

  extraPaths = (pkgs.formats.yaml { }).generate "comfyui-workstation-paths.yaml" {
    workstation_models = {
      base_path = "/models/comfyui";
    }
    // modelPathEntries;
    declarative_nodes.custom_nodes = toString declarativeNodes;
  };
in
{
  environment.systemPackages = [
    comfyui
    creativeModelPhase
    h3ModelPhase
    downloadImageUpscalerModels
    downloadMinimaxH3FunControlnet
    modelTools
    pkgs.ffmpeg-full
  ];

  # Large model artifacts are mutable operational data, not Nix-store inputs.
  # The downloader writes only SHA-pinned, checksum-verified files here.
  systemd.tmpfiles.rules = [
    "d /models/comfyui 0750 peterstorm users - -"
    "d /models/voice 0750 peterstorm users - -"
    "d /models/voice/qwen3-tts 0750 peterstorm users - -"
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
      # Keep physical GPU0 available for the prompt-author LLM. CUDA_VISIBLE_DEVICES=1
      # makes physical GPU1 ComfyUI's only visible device, renumbered to cuda:0.
      CUDA_VISIBLE_DEVICES = "1";
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
      PYTORCH_CUDA_ALLOC_CONF = "expandable_segments:True";
      MUSE_GLIMMER_BASE_URL = "http://127.0.0.1:8000/v1";
      MUSE_GLIMMER_API_KEY_FILE = "/home/peterstorm/.config/qwen38/api-key";
      MINIMAX_H3_DIRECTOR_LLM_API_KEY_FILE = "/home/peterstorm/.config/qwen38/api-key";
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
          --enable-assets \
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
  # Core covers the native workflows; the three third-party Pixaroma packs
  # above are immutable source pins required by the imported Episode 29/30 graphs.
}
