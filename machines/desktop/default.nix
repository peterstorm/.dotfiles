{ pkgs, lib, config, inputs, util, ... }:
let
  # Desired persistent per-GPU power cap in watts, or null to leave the cards at
  # their firmware default.
  #
  # Why 350: upstream's sweep (hardware/blackwell-power-limit-sweep.md) measures
  # the 600 W Workstation card holding ~300-305 Gflop/s/W flat across the whole
  # 200-350 W band. This is therefore the lowest-risk diagnostic cap that stays
  # inside the measured efficiency plateau.
  #
  # Reliability override (2026-08-16): physical GPU0 (serial 1794425022466,
  # PCI 01:00.0) fell off the bus (Xid 79) three times under Qwen3.8 SGLang
  # load: once at 450 W and twice at 400 W. A Seasonic 1600 W Platinum PSU makes
  # aggregate PSU capacity unlikely, but does not distinguish the card, its
  # connector/cable, the slot/root path, or a TP-rank-0 driver/runtime failure.
  # Keep 350 W while the logical GPU-order and physical-swap tests run. This cap
  # is mitigation, not a claimed fix. See docs/gpu-inference-crash-triage.md.
  #
  # This is a request, not an assertion: the service below clamps it into the
  # range the installed cards actually report. The SKU here is still unverified,
  # and a 600 W Workstation card and a 300 W Max-Q do not share a valid range —
  # `nvidia-smi -pl` exits non-zero outside it, which would fail the unit on
  # every boot. Clamping means the same config is correct for either card.
  gpuPowerLimitWatts = 350;

  gpuTelemetryPython = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.nvidia-ml-py
  ]);

  # --- MediaTek MT7927 / MT6639 (Filogic 380) WiFi 7 + Bluetooth -------------
  #
  # The board's card is PCI 14c3:7927, which mainline does not claim: kernel
  # 6.18.41 ships no such modalias, and linux-firmware has mediatek/mt7925 but
  # nothing for MT6639. Both halves come from cmspam/mt7927-nixos, which builds
  # patched out-of-tree mt76 + bluetooth modules and extracts the firmware from
  # ASUS's Windows driver package.
  #
  # We take its packages but re-do their install layout, because the flake's
  # default does not work on NixOS:
  #
  #   * Modules go in updates/, not extra/. depmod ranks updates/ above kernel/
  #     but does NOT rank extra/ above it, so the flake's extra/ layout loses
  #     every name collision to the in-tree mt76 modules. Verified on the built
  #     tree: modules.dep resolved mt7925e to kernel/…/mt7925e.ko.xz and
  #     modules.alias carried only the in-tree 0717/7925 aliases — no 7927 — so
  #     the card would still not have been claimed.
  #
  #   * The BT RAM code is installed to mediatek/mt7927/ as well as
  #     mediatek/mt6639/. The patched btmtk requests it from the former.
  #
  # Both corrections match what other NixOS users of this card converged on.
  mt7927 = inputs.mt7927.packages.${pkgs.stdenv.hostPlatform.system};
  kver = config.boot.kernelPackages.kernel.modDirVersion;

  mt7927Wifi = mt7927.wifi.overrideAttrs (_: {
    installPhase = ''
      runHook preInstall
      modDir="$out/lib/modules/${kver}/updates/mt76"
      install -dm755 "$modDir/mt7921" "$modDir/mt7925"
      install -m644 mt76.ko mt76-connac-lib.ko mt792x-lib.ko "$modDir/"
      install -m644 mt7921/*.ko "$modDir/mt7921/"
      install -m644 mt7925/*.ko "$modDir/mt7925/"
      runHook postInstall
    '';
  });

  mt7927Bluetooth = mt7927.bluetooth.overrideAttrs (_: {
    installPhase = ''
      runHook preInstall
      modDir="$out/lib/modules/${kver}/updates/bluetooth"
      install -dm755 "$modDir"
      install -m644 btusb.ko btmtk.ko "$modDir/"
      runHook postInstall
    '';
  });

  mt7927Firmware = mt7927.firmware.overrideAttrs (_: {
    installPhase = ''
      runHook preInstall
      install -Dm644 firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin \
        "$out/lib/firmware/mediatek/mt7927/BT_RAM_CODE_MT6639_2_1_hdr.bin"
      install -Dm644 firmware/BT_RAM_CODE_MT6639_2_1_hdr.bin \
        "$out/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"
      install -Dm644 firmware/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin \
        "$out/lib/firmware/mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"
      install -Dm644 firmware/WIFI_RAM_CODE_MT6639_2_1.bin \
        "$out/lib/firmware/mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin"
      runHook postInstall
    '';
  });
in
{
  imports = [
    inputs.disko.nixosModules.disko
    ./disks.nix
  ];

  # MT7927 WiFi + Bluetooth. Deliberately not importing
  # inputs.mt7927.nixosModules.default: it wires the same derivations in with the
  # upstream extra/ layout, which depmod ranks below the in-tree mt76 modules.
  # See the mt7927* definitions at the top of this file.
  hardware.firmware = [ mt7927Firmware ];
  boot.extraModulePackages = [
    mt7927Wifi
    mt7927Bluetooth
  ];
  boot.kernelModules = [
    "mt7925e"
    "btmtk"
    "btusb"
    # Nuvoton NCT6799D super-I/O (fan tachs + PWM). Without this, Linux sees no
    # fan/PWM interfaces at all — only the asus-ec-sensors CPU_Opt tach — and
    # the fan curves are completely invisible. See asus-fan-control below.
    "nct6775"
  ];

  # ASPM on this card is the documented cause of stalled uploads and packet loss.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", \
      ATTR{vendor}=="0x14c3", ATTR{device}=="0x7927", \
      ATTR{link/l1_aspm}="0"
  '';

  # Home-manager is NOT folded into this system closure. It is applied
  # standalone with `./hm-apply.sh desktop`, exactly like the laptops.
  #
  # (It used to be a NixOS module here so the offline USB install landed a
  # driveable user with no network on first boot. The box now has WiFi and the
  # dotfiles checked out, so that coupling is gone — the desktop's standalone HM
  # config lives in flake.nix as `homeManagerConfigurations.desktop`, a subset
  # of the laptop roles without the homelab/sops/obsidian ones that need an age
  # key.)

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Two boot entries: the base/default system is headless so the RTX 6000 Pros
  # start empty for inference; the "graphical" specialisation starts SDDM +
  # XMonad on both cards. systemd-boot lists specialisations as their own entries.
  #
  # The desktop stays one command away without rebooting:
  #   systemctl isolate graphical.target    # bring XMonad up
  #   systemctl isolate multi-user.target   # drop it again
  #
  # mkForce is required, not optional: nixpkgs sets
  #   systemd.defaultUnit = mkIf (xserver.autorun || displayManager.enable) "graphical.target"
  # in services/misc/graphical-desktop.nix. That is a normal-priority definition,
  # so a second one here conflicts rather than overrides — and it is also why
  # `services.xserver.autorun = false` does nothing while SDDM is enabled.
  systemd.defaultUnit = lib.mkForce "multi-user.target";

  # Hand the default headless console back to the firmware framebuffer. With
  # modesetting on, nvidia-drm can move the console to another connector partway
  # through boot, which looks like a hang on a two-GPU/eight-output workstation.
  # X is not running in the base profile, so nothing needs KMS.
  hardware.nvidia.modesetting.enable = lib.mkForce false;

  specialisation.graphical.configuration = {
    # Specialisations inherit the base definitions, including their mkForce
    # priority (50). Priority 40 is intentionally stronger so this opt-in profile
    # can reverse both headless defaults without creating equal-priority conflicts.
    systemd.defaultUnit = lib.mkOverride 40 "graphical.target";
    hardware.nvidia.modesetting.enable = lib.mkOverride 40 true;
  };

  # GPU-to-GPU PCIe P2P for multi-GPU inference (DS4 v8 / vLLM b12x allreduce).
  # RTX 6000 Pro (Blackwell) has no NVLink, so the allreduce path relies on
  # PCIe P2P. Requires "Above 4G Decoding" + "Resizable BAR" ON in BIOS, and
  # "ACS = Disabled" so there is no upstream translation to force P2P around.
  #
  # We use `iommu=pt` (passthrough), NOT `iommu=off`. Both give GPU↔GPU P2P the
  # untranslated path it needs, but they differ for every OTHER device:
  #
  #   * `iommu=off` tears the IOMMU out entirely. That broke the on-board
  #     MediaTek MT7927 WiFi: its firmware download is a DMA transfer, and with
  #     the AMD IOMMU fully off the MCU's replies never landed — dmesg showed
  #     `Message 00000010 timeout` → `Failed to get patch semaphore` →
  #     `hardware init failed`, and the card never came up. The exact same card
  #     worked on Ubuntu, whose only relevant difference was IOMMU left on.
  #   * `iommu=pt` keeps the IOMMU enabled and puts every device in a 1:1
  #     passthrough domain, so WiFi (and everything else) DMAs normally, while
  #     the GPUs still get an untranslated P2P path. This is the alternative the
  #     upstream direct-attach P2P notes record as working
  #     (`amd_iommu=on iommu=pt` with ACS disabled in firmware).
  #
  # The third parameter is unrelated to P2P. zfs_arc_max caps the ARC at 16 GiB;
  # OpenZFS on Linux otherwise takes half of RAM, which is exactly the half this
  # box needs for something else. Under `--ipc=host` the vLLM KV offload region
  # is an mmap in the host's /dev/shm, and the model load streams a ~155 GiB
  # checkpoint that is read once per start, sequentially, off a 1M-recordsize
  # dataset — so an unbounded ARC evicts pages that are reused to cache data
  # nobody reads twice. 16 GiB is ample for /nix and metadata.
  boot.kernelParams = [ "iommu=pt" "amd_iommu=on" "zfs.zfs_arc_max=17179869184" ];
  boot.extraModprobeConfig = ''
    options nvidia_uvm uvm_disable_hmm=1
    options nvidia NVreg_RegistryDwords="ForceP2P=0x11;RMForceP2PType=1;RMPcieP2PType=2;GrdmaPciTopoCheckOverride=1;EnableResizableBar=1"
  '';

  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "8a3f2c19";

  # Disable WiFi power-save. This is a fixed, mains-powered workstation, and the
  # MediaTek MT7927 drops the link under sustained load (e.g. a 155 GiB model
  # pull) when NetworkManager's default power management is on. Laptops keep the
  # default (battery); this is desktop-only. Wired is still preferable for the
  # big downloads — the onboard 2.5G/10G NICs need no config.
  networking.networkmanager.wifi.powersave = false;

  services.zfs = {
    autoScrub.enable = true;
    trim.enable = true;
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  hardware.cpu.amd.updateMicrocode = true;

  # Escape hatches for a config-less XMonad.
  #
  # The system XMonad recompiles ~/.xmonad/xmonad.hs, which home-manager now
  # installs — but if that recompile ever fails you fall back to stock XMonad,
  # whose bindings are Alt-based rather than the Super-based ones in that file.
  # Stock's two useful bindings are Alt+Shift+Enter (terminal) and Alt+p
  # (launcher), and dmenu was missing, so Alt+p silently did nothing. On a box
  # whose whole purpose is to be reachable, leaving the fallback path broken is
  # not worth the two packages.
  environment.systemPackages = with pkgs; [
    dmenu
    xterm

    # Hardware diagnostics. These are on the installer ISO but were missing from
    # the installed system, which is backwards: this box's whole reason for
    # existing is two GPUs on a specific PCIe topology, and the P2P verification
    # steps in docs/new-desktop-install.md are literally `lspci -PP` and
    # `lspci -vv | grep LnkSta`. Not having pciutils here meant the one machine
    # that needs to answer PCIe questions could not.
    pciutils
    usbutils
    nvme-cli
    dmidecode
    lshw
    smartmontools
    ethtool
  ];

  # Always-on workstation with no battery to protect, and a CPU that has to keep
  # up with host-side rejection sampling and input prep on the decode path —
  # those stages are eager, not captured in the CUDA graphs.
  powerManagement.cpuFreqGovernor = "performance";

  # /var/lib/docker is a ZFS dataset (see disks.nix), and dockerd's driver
  # auto-detection cannot land on overlay2 there: moby's overlay2 init refuses
  # ZFS outright, so it falls through to its `zfs` graphdriver. That driver
  # shells out to the `zfs` binary — and the NixOS module only puts
  # `boot.zfs.package` on dockerd's PATH when storageDriver is *explicitly*
  # "zfs". Leaving this unset is the difference between a working daemon and one
  # that fails to find zfs at startup, on the machine whose entire job is running
  # a 155 GiB container.
  virtualisation.docker.storageDriver = "zfs";

  # nvidia-smi -pl, declaratively, surviving reboots. Only defined when a limit
  # is actually chosen — see gpuPowerLimitWatts at the top of this file.
  # nvidiaPersistenced keeps the driver initialized, so the cap is not lost when
  # the last client detaches.
  #
  # Per GPU rather than globally, and clamped to each card's reported
  # [power.min_limit, power.max_limit], so an unsupported request is corrected
  # and logged instead of failing the unit.
  systemd.services.nvidia-power-limit = lib.mkIf (gpuPowerLimitWatts != null) {
    description = "Persistent power limit for the RTX 6000 Pro cards";
    wantedBy = [ "multi-user.target" ];
    after = [ "nvidia-persistenced.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "nvidia-power-limit";
        runtimeInputs = [
          config.hardware.nvidia.package.bin
          pkgs.coreutils
        ];
        text = ''
          want=${toString gpuPowerLimitWatts}

          # The driver can still be settling when multi-user.target is reached;
          # persistenced ordering gets us close but is not a readiness contract.
          for _ in $(seq 1 30); do
            if nvidia-smi -L >/dev/null 2>&1; then break; fi
            sleep 1
          done
          if ! nvidia-smi -L >/dev/null 2>&1; then
            echo "nvidia-smi never became ready; leaving power limits alone" >&2
            exit 1
          fi

          for idx in $(nvidia-smi --query-gpu=index --format=csv,noheader); do
            lo=$(nvidia-smi -i "$idx" --query-gpu=power.min_limit \
                   --format=csv,noheader,nounits | tr -d ' ')
            hi=$(nvidia-smi -i "$idx" --query-gpu=power.max_limit \
                   --format=csv,noheader,nounits | tr -d ' ')
            # Reported as e.g. "600.00"; -pl takes whole watts.
            lo=''${lo%%.*}
            hi=''${hi%%.*}

            target=$want
            if [ "$target" -gt "$hi" ]; then
              echo "GPU $idx: requested ''${want}W above max ''${hi}W - clamping"
              target=$hi
            elif [ "$target" -lt "$lo" ]; then
              echo "GPU $idx: requested ''${want}W below min ''${lo}W - clamping"
              target=$lo
            fi

            echo "GPU $idx: setting power limit to ''${target}W (range ''${lo}-''${hi}W)"
            nvidia-smi -i "$idx" -pl "$target"
          done
        '';
      });
    };
  };

  # One-second, per-physical-GPU telemetry for the recurrent Xid 79 diagnosis.
  # Daily CSV files retain the final power/temperature/link samples across a
  # reboot without depending on Prometheus availability or scrape timing.
  systemd.services.gpu-telemetry-record = {
    description = "Record durable per-GPU health telemetry";
    wantedBy = [ "multi-user.target" ];
    wants = [ "nvidia-power-limit.service" ];
    after = [ "nvidia-persistenced.service" "nvidia-power-limit.service" ];
    environment = {
      GPU_TELEMETRY_DIR = "/var/lib/gpu-telemetry";
      GPU_TELEMETRY_INTERVAL = "1";
      GPU_TELEMETRY_SLOW_INTERVAL = "10";
      GPU_TELEMETRY_FSYNC_INTERVAL = "1";
      LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${gpuTelemetryPython}/bin/python3 ${../../scripts/gpu-telemetry-record.py}";
      Restart = "always";
      RestartSec = "3s";
      DynamicUser = true;
      StateDirectory = "gpu-telemetry";
      StateDirectoryMode = "0750";
      UMask = "0027";
      CapabilityBoundingSet = "";
      RestrictAddressFamilies = [ "AF_UNIX" ];
      Nice = 10;
      IOSchedulingClass = "idle";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ "/var/lib/gpu-telemetry" ];
    };
  };

  # --- Fan control for the NCT6799D (ProArt X870E-CREATOR) ------------------
  #
  # The board's fan logic lives in a Nuvoton NCT6799D super-I/O chip exposed by
  # the nct6775 driver (binds as `nct6799`). Two hard-won facts shaped this:
  #
  #   * The stock BIOS SmartFan IV profile has a trap: the CPU_FAN curve
  #     references SYSTIN (motherboard temp, ~40 °C) instead of the CPU, so the
  #     CPU cooler idles at ~34 % duty while the package sits at Tjmax.
  #   * SmartFan IV mode (enable=5) is not trustworthy for our curves here:
  #     after a while the chip/EC re-asserts its own duty (~65 %) regardless of
  #     the register values we wrote, and write-back readouts drift. Manual mode
  #     (enable=1) is rock-solid — duty holds exactly until changed.
  #
  # So instead of fighting the chip's engine, this drives both fans in MANUAL
  # mode from userspace: a oneshot at boot plus a 60 s timer re-read the CPU's
  # PECI temp (temp8), interpolate the curve, and write the duty. Deterministic,
  # immune to the EC re-asserting registers, and self-healing: any tick that
  # finds enable flipped back repairs it within a minute.
  #
  # Curves (PECI temp → duty 0-255):
  #   * CPU fan (pwm1/fan1): 90 (35 %) @ 40 °C … 255 (100 %) @ 70 °C
  #   * Case fan (pwm6/fan6): 80 (31 %) @ 30 °C … 255 (100 %) @ 70 °C
  #
  # fan2 (CPU_OPT) keeps its BIOS curve — it was already PECI-driven and runs
  # at ~100 % under load. PWM channels 3/4/5/7 read 0 RPM even at full duty:
  # no tach signal, so no fans (or tach-less fans) on those headers — the three
  # physical case fans (2 front + 1 rear) share CHA_FAN1's tach or are wired
  # without tach feedback.
  systemd.services.asus-fan-control = {
    description = "PECI-driven fan duty controller for the NCT6799D (ProArt X870E-CREATOR)";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe (pkgs.writeShellApplication {
        name = "asus-fan-control";
        runtimeInputs = [ pkgs.coreutils ];
        text = ''
          # The /sys/class/hwmon index is probe-order dependent; find the
          # nct6799 chip by driver name instead.
          h=""
          for _ in $(seq 1 30); do
            for d in /sys/class/hwmon/hwmon*; do
              if [ -r "$d/name" ] && [ "$(cat "$d/name" 2>/dev/null)" = "nct6799" ]; then
                h=$d; break 2
              fi
            done
            sleep 1
          done
          if [ -z "$h" ]; then
            echo "nct6799 hwmon dir not found; is nct6775 loaded?" >&2
            exit 1
          fi

          set -e
          ed() { printf '%s\n' "$2" > "$h/$1"; }

          # Linear interpolation between (t0,p0) and (t1,p1); temps in millidegrees.
          interp() {
            t=$1; t0=$2; p0=$3; t1=$4; p1=$5
            if [ "$t" -le "$t0" ]; then echo "$p0"; return; fi
            if [ "$t" -ge "$t1" ]; then echo "$p1"; return; fi
            echo $(( p0 + (p1 - p0) * (t - t0) / (t1 - t0) ))
          }

          peci=$(cat "$h/temp8_input")

          # CPU fan (fan1): 90 @ 40 °C … 255 @ 70 °C
          d1=$(interp "$peci" 40000 90 70000 255)
          # Case fan (fan6): 80 @ 30 °C … 255 @ 70 °C
          d6=$(interp "$peci" 30000 80 70000 255)

          ed pwm1_enable 1
          ed pwm1 "$d1"
          ed pwm6_enable 1
          ed pwm6 "$d6"
        '';
      });
    };
  };

  systemd.timers.asus-fan-control = {
    description = "Re-apply NCT6799D fan duties every minute";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30";
      OnUnitActiveSec = "60";
    };
  };


  # --- Local inference token ledger + heatmap -------------------------------
  #
  # The homelab's Prometheus only keeps 30d of history and dies on cluster
  # wipes (k3s uninstall/reinstall), and inference-engine /metrics counters
  # reset with every container restart or runtime switch. To keep a true lifetime stat, record
  # per-interval token deltas into an append-only CSV on this box's disk
  # (/var/lib/vllm-stats/stats.csv) every 15 minutes, and render a
  # GitHub-style heatmap from it. The CSV survives everything except the disk.
  systemd.services.vllm-stats-record = {
    description = "Append local inference token usage deltas to the durable ledger";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.python3}/bin/python3 ${../../scripts/vllm-stats-record.py}"
        "${pkgs.python3}/bin/python3 ${../../scripts/vllm-stats-heatmap.py} --write"
      ];
    };
  };

  systemd.timers.vllm-stats-record = {
    description = "Run the local inference stats recorder every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/15";
      Persistent = true;    # catch up after downtime instead of skipping
      RandomizedDelaySec = 45;
    };
  };

  # Serve the token heatmap (and raw stats.csv) over HTTP:8090. Reached as
  # vllm-stats.peterstorm.io, an unproxied A record pointing straight here — so
  # LAN clients and WARP-enrolled devices resolve it, but the internet cannot
  # route to it. Read-only static files, and note there is no auth in front of
  # this: the unroutable address *is* the access control.
  systemd.services.vllm-stats-http = {
    description = "Serve the local inference stats heatmap over HTTP";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "vllm-stats-record.service" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8090 --bind 0.0.0.0 --directory /var/lib/vllm-stats/heatmap";
      Restart = "on-failure";
      RestartSec = 5;
      # read-only view of the heatmap dir; everything else is locked down
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      ReadOnlyPaths = [ "/var/lib/vllm-stats/heatmap" ];
      NoNewPrivileges = true;
      DynamicUser = true;
    };
    wantedBy = [ "multi-user.target" ];
  };

  # Reachable as `desktop.local` without hunting for an IP.
  #
  # The `wifi` role enables the avahi daemon and mDNS *resolution* for every
  # host. Publishing (announcing this box as `desktop.local`) is opt-in and set
  # here, because this is a fixed headless workstation you only ever reach over
  # SSH — unlike a laptop joining strange networks, which should stay quiet.
  # avahi.openFirewall defaults to true, so UDP 5353 is handled.
  services.avahi = {
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    # Only announce on the physical NICs. Without this, avahi also publishes
    # `desktop.local` on docker0 (172.17.0.1) and every transient docker
    # `br-*`/`veth*` bridge this box spins up for the vLLM containers, so a
    # client resolving the name can land on a non-routable address instead of
    # the LAN one. Whitelisting the real interfaces keeps the A record clean.
    allowInterfaces = [ "wlp10s0" "enp11s0" "enp12s0" ];
  };

  # Expose the vLLM / DS4 v8 OpenAI-compatible server (PORT=8000, --network host)
  # to the LAN, plus the stats heatmap server (8090). sshd opens 22 itself; the
  # wifi role opens 8081. Merges with those.
  networking.firewall.allowedTCPPorts = [ 8000 8090 ];
}
