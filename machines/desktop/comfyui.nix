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
    "controlnet"
    "upscale_models"
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

  eliteWorkflows =
    pkgs.runCommand "comfyui-elite-workflows"
      {
        nativeBuildInputs = [
          pkgs.gnugrep
          pkgs.jq
        ];
      }
      ''
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
          "$krea_style_bf16"; then
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
                gsub("minimax_h3_fl2va_pruned_int8_convrot\\.safetensors";
                  "minimax_h3_fl2va_bf16.safetensors")
                | gsub("minimax_h3_ref2va_pruned_int8_convrot\\.safetensors";
                    "minimax_h3_ref2va_bf16.safetensors")
                | gsub("qwen3vl_32b_minimax_h3_nvfp4_awq\\.safetensors";
                    "qwen3vl_32b_minimax_h3_bf16.safetensors")
                | gsub("https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/";
                    "https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/dc559027db79c174125df4d827db55cd11178860/")
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

        test "$(${pkgs.findutils}/bin/find "$out" -type f -name '*.json' | wc -l)" -eq 53
      '';

  pixaromaEp24 =
    pkgs.runCommand "pixaroma-ep24-krea2-bf16-workflows"
      {
        nativeBuildInputs = [
          pkgs.findutils
          pkgs.gnugrep
          pkgs.jq
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

        jq -s -e '
          length == 11
          and ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | length == 11 and all(.[]; . == "krea2_turbo_bf16.safetensors"))
          and ([.[] | .nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
            | ([.[] | select(. == "qwen3vl_4b_bf16.safetensors")] | length == 8)
              and ([.[] | select(. == "${krea2AbliteratedEncoder}")] | length == 3))
          and ([.[] | .nodes[] | select(.type == "VAELoader") | .widgets_values[0]]
            | length == 11 and all(.[]; . == "qwen_image_vae.safetensors"))
          and ([.[] | .nodes[] | select(.type == "KSampler") | .widgets_values[2]]
            | length == 17
              and ([.[] | select(. == 8)] | length == 11)
              and ([.[] | select(. == 4)] | length == 6))
          and ([.[] | .nodes[] | select(.type == "TextGenerate")] | length == 6)
          and ([.[] | .nodes[] | select(.type == "VAEDecodeTiled")] | length == 1)
          and ([.[] | .nodes[] | select(.type == "LatentUpscaleBy")] | length == 6)
          and ([.[] | .nodes[] | select(.type == "ComfyUI-Krea2T-Enhancer")] | length == 11)
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
              "CLIPLoader", "CLIPTextEncode", "ComfyUI-Krea2T-Enhancer",
              "ConditioningZeroOut", "EmptySD3LatentImage", "KSampler",
              "LatentUpscaleBy", "LoraLoaderModelOnly", "PixaromaLabel",
              "PixaromaNote", "PixaromaPortraitLandscape", "PixaromaPreview",
              "PixaromaResolution", "PixaromaRunTimer", "PixaromaSeed",
              "PixaromaShowText", "StringConcatenate", "TextGenerate",
              "UNETLoader", "VAEDecode", "VAEDecodeTiled", "VAELoader"
            ] | index($type) | not))] | length == 0)
        ' "$out"/workflows/*.json >/dev/null
        if grep -RqiE 'fp8|int8|rgthree|resolve/main|tree/main|uncensored|unrestricted|krea2RealVae' \
          "$out/workflows"; then
          echo "forbidden Episode 24 model, node, or mutable link" >&2
          exit 1
        fi
        test "$(${pkgs.findutils}/bin/find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 11
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
          jq -e . "$workflow" >/dev/null
        done

        test "$(find "$out/workflows" -type f -name '*.json' | wc -l)" -eq 7
        test "$(find "$out/media" -type f | wc -l)" -eq 6
        jq -s -e '
          ([.[] | .nodes[] | select(.type == "UNETLoader") | .widgets_values[0]]
            | length == 5 and all(.[]; . == "krea2_turbo_bf16.safetensors"))
          and ([.[] | .nodes[] | select(.type == "CLIPLoader") | .widgets_values[0]]
            | length == 5 and all(.[]; . == "qwen3vl_4b_bf16.safetensors"))
        ' "$out/workflows"/*.json >/dev/null
        if grep -RqiE 'krea2_turbo_(int8|fp8)|qwen3vl_4b_fp8|qwen3-vl-4b-heretic_int8|qwen3-vl-8b-heretic-1.3.0-int8convrot|craftingmod|resolve/main|tree/main' \
          "$out/workflows"; then
          echo "forbidden Episode 30 lower-precision selector or mutable link" >&2
          exit 1
        fi
      '';

  installCreativeWorkflows = pkgs.writeShellScript "install-creative-workflows" ''
    set -eu
    user_workflows=/var/lib/comfyui/user/default/workflows
    ep24_dir="$user_workflows/pixaroma-ep24-krea2-bf16"
    ep29_dir="$user_workflows/pixaroma-ep29-h3-bf16"
    ep30_dir="$user_workflows/pixaroma-ep30"
    elite_dir="$user_workflows/creative-suite"
    ep24_staging="$user_workflows/.pixaroma-ep24-krea2-bf16.new"
    ep29_staging="$user_workflows/.pixaroma-ep29-h3-bf16.new"
    ep30_staging="$user_workflows/.pixaroma-ep30.new"
    elite_staging="$user_workflows/.creative-suite.new"
    input_dir=/var/lib/comfyui/input
    rm -rf "$ep24_staging" "$ep29_staging" "$ep30_staging" "$elite_staging"
    install -d -m 0700 \
      "$ep24_staging" "$ep29_staging" "$ep30_staging" "$elite_staging" "$input_dir"
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
    for category in ${eliteWorkflows}/*; do
      destination="$elite_staging/$(basename "$category")"
      install -d -m 0700 "$destination"
      for source in "$category"/*.json; do
        install -m 0600 "$source" "$destination/$(basename "$source")"
      done
    done
    rm -rf "$ep24_dir" "$ep29_dir" "$ep30_dir" "$elite_dir"
    mv "$ep24_staging" "$ep24_dir"
    mv "$ep29_staging" "$ep29_dir"
    mv "$ep30_staging" "$ep30_dir"
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
  # Core covers the native workflows; the three third-party Pixaroma packs
  # above are immutable source pins required by the imported Episode 29/30 graphs.
}
