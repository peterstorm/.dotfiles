{ pkgs, lib, ... }:

# Route audio to the ultrawide DELL U3818DW by default.
#
# The monitors hang off the GPU's HDA controller (PCI 0000:01:00.1). That card
# exposes one DP/HDMI output at a time via its *profile*, and only the ultrawide
# (on `output:hdmi-stereo-extra1`, i.e. "Digital Stereo (HDMI 2)") has speakers.
# WirePlumber's default is the plain `hdmi-stereo` output (the speaker-less
# U2719D), so out of the box you get a moving volume meter and silence.
#
# This enforces, on every login, the card profile that lights up the ultrawide's
# output and makes that sink the default. Names are PCI-based and stable across
# reboots. Switch to the headset any time in pavucontrol; it reverts next login.
let
  card = "alsa_card.pci-0000_01_00.1";
  profile = "output:hdmi-stereo-extra1";
  sink = "alsa_output.pci-0000_01_00.1.hdmi-stereo-extra1";

  setDefaultAudio = pkgs.writeShellScript "set-default-audio" ''
    pactl="${pkgs.pulseaudio}/bin/pactl"

    # Wait for the GPU HDA card to be enumerated (PipeWire/WirePlumber startup
    # races the login), up to ~15s.
    for _ in $(seq 1 30); do
      if "$pactl" list cards short 2>/dev/null | grep -q "${card}"; then break; fi
      sleep 0.5
    done

    # Activate the output that drives the ultrawide's speakers.
    "$pactl" set-card-profile "${card}" "${profile}" || true

    # The sink appears once the profile is active; wait for it, then make it
    # the default.
    for _ in $(seq 1 20); do
      if "$pactl" list sinks short 2>/dev/null | grep -q "${sink}"; then break; fi
      sleep 0.5
    done
    "$pactl" set-default-sink "${sink}" || true
  '';
in
{
  systemd.user.services.default-audio-sink = {
    Unit = {
      Description = "Default audio to the ultrawide monitor (GPU HDMI 2)";
      After = [ "pipewire-pulse.service" "wireplumber.service" ];
      Wants = [ "pipewire-pulse.service" "wireplumber.service" ];
    };
    Service = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${setDefaultAudio}";
    };
    Install.WantedBy = [ "default.target" ];
  };
}
