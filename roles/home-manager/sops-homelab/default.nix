{ lib, config, pkgs, util, ... }:

# Minimal sops config for homelab - only secrets decryptable with the homelab age key
(util.sops.mkSecretsAndTemplatesConfig
  [
    (util.sops.userSecret "gemini-api-key" "gemini.yaml" "api_key")
  ]
  [
    (util.sops.envTemplate "gemini-env" {
      GEMINI_API_KEY = "gemini-api-key";
    })
  ]
  {}
) { inherit config lib; }
