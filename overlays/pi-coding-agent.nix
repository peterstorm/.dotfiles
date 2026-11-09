# Pi coding agent = numtide/llm-agents.nix's package + our patches.
#
# Version, source hash, lockfile and npm deps hash all come from the `llm-agents`
# flake input, so `nix flake update` is what upgrades Pi. Nothing here pins a
# version. When a new upstream release no longer applies one of the patches the
# build fails in patchPhase — rebase the patch (see overlays/patches/pi-*.patch).
#
# Why not use upstream's package untouched:
#
#  * Patches. They are made against the *unbundled* `dist/` tree of the npm
#    tarball, so they cannot touch `dist/bundle/` (minified, what upstream's
#    default `bin` runs) nor the Bun standalone binary built from it.
#  * Node entry point. `useBun = false` keeps the node_modules layout under
#    $out/lib/node_modules that pi/verify.sh and tests/pi-compaction-autocontinue-
#    contract.sh resolve the Pi SDK from, and `bin` is pointed at the unbundled
#    `dist/cli.js` so the patched files are what actually runs.
inputs: final: prev:

let
  upstream = inputs.llm-agents.packages.${prev.stdenv.hostPlatform.system}.pi;
in
{
  pi-coding-agent = (upstream.override { useBun = false; }).overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      # models.json `defaultThinkingLevel`: a model-local default that applies at
      # startup and on model switches without mutating the global default. An
      # explicit level (--thinking, ctrl+t, SDK `thinkingPreference`) is pinned
      # for the session; scoped and per-model settings levels still win.
      ./patches/pi-model-default-thinking.patch
      # Threshold auto-compaction used to end the agent turn (waiting for input)
      # unless the user had queued a message. autoContinue resumes the turn from
      # the compaction boundary; disable with {"compaction": {"autoContinue": false}}.
      ./patches/pi-autocontinue-after-compact.patch
      # `pi.sendUserMessage("/cmd", { deliverAs: "followUp", executeCommandAfterIdle:
      # true })` waits for the current run to settle, then invokes only a
      # registered extension command. Upstream's `expandPromptTemplates` runs the
      # command immediately, even mid-run, which is wrong for a model-scheduled
      # /reload.
      ./patches/pi-extension-command-after-idle.patch
    ];

    postPatch = (old.postPatch or "") + ''
      substituteInPlace package.json \
        --replace-fail '"pi": "dist/bundle/cli.js"' '"pi": "dist/cli.js"'
    '';
  });
}
