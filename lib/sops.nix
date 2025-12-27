{ lib, ... }:

with lib;

rec {
  # Create a single sops secret configuration
  # Automatically resolves context (NixOS vs home-manager) and user info
  mkSecret = {
    name,                    # Secret identifier
    file,                    # Sops file path (relative to repo root)
    key ? name,              # Key within sops file (defaults to name)  
    owner ? "auto",          # File owner ("auto" for dynamic, null to omit, or explicit user)
    group ? "auto",          # File group ("auto" for dynamic, null to omit, or explicit group)
    mode ? "0400",           # File permissions
    path ? null,             # Custom secret path (optional, auto-generated if null)
    format ? "yaml",         # Sops file format
  }: { config, ... }:
  let
    # Detect if we're in home-manager context
    isHomeManager = config ? home;
    
    # Get current user dynamically
    currentUser = if isHomeManager 
      then config.home.username
      else config.users.users ? root; # fallback detection
    
    # Resolve owner dynamically
    resolvedOwner = 
      if owner == "auto" then
        if isHomeManager then null  # home-manager doesn't need owner
        else currentUser
      else if owner == null then null
      else owner;
    
    # Resolve group dynamically  
    resolvedGroup =
      if group == "auto" then
        if isHomeManager then null  # home-manager doesn't need group
        else "users"  # reasonable default for NixOS
      else if group == null then null
      else group;
    
    # Generate path if not specified
    resolvedPath = 
      if path != null then path
      else if isHomeManager then null  # let home-manager decide
      else "/run/secrets/${name}";  # NixOS default location
      
  in {
    sops.secrets.${name} = {
      sopsFile = ../. + "/${file}";  # Resolve relative to repo root
      inherit key format mode;
    } // optionalAttrs (resolvedOwner != null) { owner = resolvedOwner; }
      // optionalAttrs (resolvedGroup != null) { group = resolvedGroup; }
      // optionalAttrs (resolvedPath != null) { path = resolvedPath; };
  };

  # Create multiple sops secrets from a list - low-level function
  # Each item in the list should be a secret spec (same as mkSecret args)
  # Supports both static specs and dynamic functions that resolve based on config
  mkSecrets = secrets: { config, ... }:
    let
      resolveSecret = secret:
        if builtins.isFunction secret
        then (mkSecret (secret { inherit config; })) { inherit config; }
        else (mkSecret secret) { inherit config; };
    in
    foldl' recursiveUpdate {} (map resolveSecret secrets);
    
  # Dynamic path resolution helpers - these resolve paths based on current context
  
  # User-specific secret - resolves to secrets/users/{current-username}/filename
  userSecret = name: filename: key: { config, ... }: 
  let
    isHomeManager = config ? home;
    currentUser = if isHomeManager then config.home.username else "unknown";
    resolvedFile = "secrets/users/${currentUser}/${filename}";
  in {
    inherit name key;
    file = resolvedFile;
    format = "yaml";
  };

  # Host-specific secret - resolves to secrets/hosts/{current-hostname}/filename  
  hostSecret = name: filename: key: attrs: { config, ... }:
  let
    currentHost = config.networking.hostName or "unknown";
    resolvedFile = "secrets/hosts/${currentHost}/${filename}";
  in {
    inherit name key;
    file = resolvedFile;
    format = "yaml";
  } // attrs;

  # Common secret - resolves to secrets/common/filename
  commonSecret = name: filename: key: {
    inherit name key;
    file = "secrets/common/${filename}";
    format = "yaml";
  };



  # TEMPLATE-BASED API (RECOMMENDED for security - avoids nix store)
  # Templates use placeholders and generate files with actual secret values
  
  # Combined secrets + templates configuration - this defines both secrets and templates together
  mkSecretsAndTemplatesConfig = secretsSpecs: templatesSpecs: extraConfig: { config, lib, ... }:
    let
      # First define all the secrets
      secretsConfig = mkSecrets secretsSpecs { inherit config; };
      
      # Then define templates that reference those secrets via placeholders
      templatesConfig = lib.foldl' lib.recursiveUpdate {} (map (templateSpec:
        let
          template = if builtins.isFunction templateSpec
                    then templateSpec { inherit config; }
                    else templateSpec;
        in {
          sops.templates.${template.name} = {
            content = template.content;
          } // (lib.optionalAttrs (template ? owner) { owner = template.owner; })
            // (lib.optionalAttrs (template ? group) { group = template.group; })
            // (lib.optionalAttrs (template ? mode) { mode = template.mode; });
        }
      ) templatesSpecs);
    in
    lib.recursiveUpdate 
      (lib.recursiveUpdate secretsConfig templatesConfig)
      extraConfig;

  # Template helpers for common patterns
  
  # Create environment file template from secret placeholders
  # Usage: envTemplate "app-env" { API_KEY = "github-token"; DB_PASS = "db-password"; }
  envTemplate = name: envVars: { config, ... }:
  let
    envContent = concatStringsSep "\n" (mapAttrsToList (envName: secretName:
      "export ${envName}='${config.sops.placeholder.${secretName}}'"
    ) envVars);
  in {
    inherit name;
    content = envContent;
  };

  # Create config file template with secret substitution
  # Usage: configTemplate "nginx.conf" "server { ssl_cert ${config.sops.placeholder.\"ssl-cert\"}; }"
  configTemplate = name: content: {
    inherit name content;
  };

  # Dynamic template helpers that work with our secret organization
  
  # User environment template - creates .env file with user-specific secrets
  userEnvTemplate = name: envVars: { config, ... }:
  let
    isHomeManager = config ? home;
    currentUser = if isHomeManager then config.home.username else "unknown";
    envContent = concatStringsSep "\n" (mapAttrsToList (envName: secretInfo:
      let
        secretName = "${currentUser}-${secretInfo.name}";
      in "export ${envName}='${config.sops.placeholder.${secretName}}'"
    ) envVars);
  in {
    inherit name;
    content = envContent;
  };

  # Host config template - creates config file with host-specific secrets
  hostConfigTemplate = name: templateContent: { config, ... }:
  let
    currentHost = config.networking.hostName or "unknown";
  in {
    inherit name;
    content = templateContent;
  };

  # Simplified API for common use case: secrets + single template + config
  mkSecretTemplate = {
    secrets,                 # List of secret specs (same as mkSecrets)
    template,                # Template spec: { name, content, owner?, group?, mode? }
    config ? {}              # Additional configuration
  }: { config, lib, ... }:
    let
      # Define secrets
      secretsConfig = mkSecrets secrets { inherit config; };
      
      # Define template
      templateConfig = {
        sops.templates.${template.name} = {
          content = template.content;
        } // (lib.optionalAttrs (template ? owner) { owner = template.owner; })
          // (lib.optionalAttrs (template ? group) { group = template.group; })
          // (lib.optionalAttrs (template ? mode) { mode = template.mode; });
      };
    in
    lib.recursiveUpdate 
      (lib.recursiveUpdate secretsConfig templateConfig)
      config;
}
