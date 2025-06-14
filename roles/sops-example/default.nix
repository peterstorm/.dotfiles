{ lib, config, pkgs, util, ... }:

# Clean example of NixOS role using dynamic host-specific encrypted secrets  
(util.sops.mkSecretsConfig [
  # Test token (dynamically resolves to current host)
  (util.sops.hostSecret "test-token" "example.yaml" "api_token" {
    owner = "root";
    group = "root"; 
    mode = "0400";
  })
  
  # Zone ID for DNS configuration (dynamically resolves to current host)
  (util.sops.hostSecret "zone-id" "example.yaml" "zone_id" {
    owner = "root";
    group = "root";
    mode = "0444"; # World-readable since it's not sensitive
  })
] {

  # Example service configuration using the secrets
  systemd.services.example-sops-service = {
    description = "Example service using host-specific sops secrets";
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "sops-example" ''
        echo "Host: $(hostname)"
        echo "Test token available at: ${config.sops.secrets.test-token.path}"
        echo "Zone ID available at: ${config.sops.secrets.zone-id.path}"
        echo "Example usage:"
        echo "  export TEST_TOKEN=$(cat ${config.sops.secrets.test-token.path})"
        echo "  export ZONE_ID=$(cat ${config.sops.secrets.zone-id.path})"
      ''}";
    };
  };
}) { inherit config lib; }