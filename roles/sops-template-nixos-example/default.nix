{ lib, config, pkgs, util, ... }:

# Example of SECURE template-based sops usage for NixOS - avoids nix store exposure
(util.sops.mkSecretsAndTemplatesConfig
  # 1. Define secrets (these get decrypted to /run/secrets/)
  [
    # Host-specific test credentials
    (util.sops.hostSecret "test-api-key" "example.yaml" "api_token" {
      owner = "root";
      group = "root";
    })
    
    # Host-specific zone ID
    (util.sops.hostSecret "test-zone-id" "example.yaml" "zone_id" {
      owner = "root";
      group = "root";
    })
  ]
  
  # 2. Define templates (these generate files with actual secret values)
  [
    # Service environment file
    (util.sops.envTemplate "nixos-service-env" {
      API_KEY = "test-api-key";
      ZONE_ID = "test-zone-id";
    })
    
    # Config file template
    (util.sops.configTemplate "nixos-app-config" ''
      [service]
      api_key = "${config.sops.placeholder."test-api-key"}"
      zone_id = "${config.sops.placeholder."test-zone-id"}"
      
      [logging]
      level = "info"
      host = "laptop-xps"
    '')
    
    # Script template with secrets
    (util.sops.configTemplate "nixos-test-script" ''
      #!/bin/bash
      echo "NixOS Template Test Script"
      echo "API Key: ${config.sops.placeholder."test-api-key"}"
      echo "Zone ID: ${config.sops.placeholder."test-zone-id"}"
      echo "Template location: ${config.sops.templates."nixos-service-env".path}"
    '')
  ]
  
  # 3. Regular NixOS configuration that uses the templates
  {
    # Example systemd service that uses the template
    systemd.services.nixos-template-test = {
      description = "NixOS Template Test Service (secure)";
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        # Use the rendered environment file
        EnvironmentFile = config.sops.templates."nixos-service-env".path;
        ExecStart = "${pkgs.writeShellScript "nixos-template-test" ''
          echo "=== NixOS SOPS Template Test ==="
          echo "Host: $(hostname)"
          echo ""
          echo "Template files with actual secret values:"
          echo "  Environment: ${config.sops.templates."nixos-service-env".path}"
          echo "  Config: ${config.sops.templates."nixos-app-config".path}"
          echo "  Script: ${config.sops.templates."nixos-test-script".path}"
          echo ""
          echo "Environment variables from template:"
          echo "  API_KEY=$API_KEY"
          echo "  ZONE_ID=$ZONE_ID"
          echo ""
          echo "Secrets are NOT in nix store - only in rendered templates!"
          echo "Templates are generated at activation time with proper permissions."
        ''}";
      };
    };
    
    # Make test script executable and available
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "test-nixos-templates" ''
        echo "Testing NixOS SOPS Templates..."
        echo ""
        echo "Template files:"
        ls -la /run/secrets/rendered/ 2>/dev/null || echo "No templates found"
        echo ""
        echo "Running service to test templates:"
        systemctl start nixos-template-test.service
        echo ""
        echo "Service output:"
        journalctl -u nixos-template-test.service --no-pager -n 20
      '')
    ];
  }
) { inherit config lib; }