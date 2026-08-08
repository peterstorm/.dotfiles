{ pkgs, lib, config, inputs, util, ... }:
let
  # Desired persistent per-GPU power cap in watts, or null to leave the cards at
  # their firmware default.
  #
  # Why 450: upstream's sweep (hardware/blackwell-power-limit-sweep.md) measures
  # the 600 W Workstation card holding ~300-305 Gflop/s/W flat across the whole
  # 200-350 W band, and only reaching peak throughput at the full 600 W. Two of
  # those is 1200 W of GPU alone in a consumer ATX case with shared airflow.
  # Capping each at 450 gives up a few percent of throughput and buys back most
  # of the thermals and noise — and on a two-up build, less throttling can leave
  # *sustained* clocks higher than the uncapped pair.
  #
  # This is a request, not an assertion: the service below clamps it into the
  # range the installed cards actually report. The SKU here is still unverified,
  # and a 600 W Workstation card and a 300 W Max-Q do not share a valid range —
  # `nvidia-smi -pl` exits non-zero outside it, which would fail the unit on
  # every boot. Clamping means the same config is correct for either card.
  gpuPowerLimitWatts = 450;

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
    inputs.home-manager.nixosModules.home-manager
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
  ];

  # ASPM on this card is the documented cause of stalled uploads and packet loss.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", \
      ATTR{vendor}=="0x14c3", ATTR{device}=="0x7927", \
      ATTR{link/l1_aspm}="0"
  '';

  # Home-manager as part of the *system* closure, not a separate `hm-apply.sh`.
  #
  # This machine is installed from an offline USB stick. Standalone home-manager
  # needs to build its own closure, which needs a network the box does not have
  # on first boot — so the old flow produced a fully working system with an
  # unusable user: a stock XMonad with none of these keybindings, no launcher,
  # and no way to fix it without the network you were trying to configure.
  # Folding the user environment into the system closure means `install-desktop`
  # lands a machine you can actually drive.
  #
  # Roles are a deliberate subset of the laptop's. The homelab ones
  # (sops-homelab, obsidian-*, vdirsyncer, sonarr-missing-search) all want an age
  # key that is deliberately not in the image, and would fail activation on a
  # fresh boot.
  #
  # NOTE: do not run ./hm-apply.sh on this host. The standalone and
  # NixOS-module home-managers would fight over the same dotfiles. Use
  # ./system-apply.sh, which now applies both.
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    # Activation refuses to clobber files it did not write; the installed system
    # already has a home directory. Move them aside rather than fail the switch.
    backupFileExtension = "hm-bak";
    extraSpecialArgs = { inherit inputs util; };
    users.peterstorm = {
      imports = [
        ../../roles/home-manager/core-apps
        ../../roles/home-manager/window-manager/xmonad
        ../../roles/home-manager/dunst
      ];
      home.username = "peterstorm";
      home.homeDirectory = "/home/peterstorm";
      home.stateVersion = "22.11";
    };
  };

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Two boot entries: the default is the workstation (X11 + SDDM + XMonad on the
  # RTX 6000 Pros), "headless" boots to a console so the GPUs start empty for
  # inference. systemd-boot lists specialisations as their own entries.
  #
  # Only the default systemd unit changes, so the desktop stays one command away:
  #   systemctl isolate graphical.target    # bring XMonad up without rebooting
  #   systemctl isolate multi-user.target   # drop it again
  #
  # mkForce is required, not optional: nixpkgs sets
  #   systemd.defaultUnit = mkIf (xserver.autorun || displayManager.enable) "graphical.target"
  # in services/misc/graphical-desktop.nix. That is a normal-priority definition,
  # so a second one here conflicts rather than overrides — and it is also why
  # `services.xserver.autorun = false` does nothing while SDDM is enabled.
  specialisation.headless.configuration = {
    systemd.defaultUnit = lib.mkForce "multi-user.target";

    # Also hand the console back to the firmware framebuffer.
    #
    # With modesetting on, nvidia-drm takes over the console partway through
    # boot and can move it to a different connector than the one firmware was
    # using. On a two-GPU box with up to eight outputs that reliably looks like
    # a hang: messages scroll normally, then the screen freezes on the last line
    # while the machine is fine and the login prompt is on a port you are not
    # plugged into. Headless mode exists precisely to do console work, so it
    # should not be the mode where the console can vanish. X is not running
    # here, so nothing needs KMS.
    hardware.nvidia.modesetting.enable = lib.mkForce false;
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

  # Reachable as `desktop.local` without hunting for an IP.
  #
  # The `wifi` role already enables avahi, but only the daemon — `publish.*` and
  # `nssmdns*` all default to false, so it neither announces itself nor resolves
  # .local names. That is a sane default for a laptop joining strange networks;
  # it is the wrong one for a fixed headless box on your own LAN that you only
  # ever reach over SSH. Set here rather than in the role so the laptops keep the
  # quiet behaviour. avahi.openFirewall defaults to true, so UDP 5353 is handled.
  services.avahi = {
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    nssmdns4 = true;
  };

  # Expose the vLLM / DS4 v8 OpenAI-compatible server (PORT=8000, --network host)
  # to the LAN. sshd opens 22 itself; the wifi role opens 8081. Merges with those.
  networking.firewall.allowedTCPPorts = [ 8000 ];
}
