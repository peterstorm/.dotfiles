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
    
  # PREFERRED API: Create secrets and merge with other config - this is what you should use!
  # Usage: util.sops.mkSecretsConfig [secrets] { your other config }
  mkSecretsConfig = secrets: extraConfig: 
    { config, lib, ... }:
    lib.recursiveUpdate 
      (mkSecrets secrets { inherit config; })
      extraConfig;
      
  # Pure secrets-only module (for imports or when you only need secrets)
  mkSecretsModule = secrets: { config, ... }:
    mkSecrets secrets { inherit config; };

  # Helper to construct secret file paths
  secretFile = filename: "secrets/${filename}";

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

  # Environment file helpers with dynamic paths
  userEnvFile = name: filename: { config, ... }:
  let
    isHomeManager = config ? home;
    currentUser = if isHomeManager then config.home.username else "unknown";
  in {
    inherit name;
    file = "secrets/users/${currentUser}/${filename}";
    format = "dotenv";
  };

  hostEnvFile = name: filename: { config, ... }:
  let
    currentHost = config.networking.hostName or "unknown";
  in {
    inherit name;
    file = "secrets/hosts/${currentHost}/${filename}";
    format = "dotenv";
  };

  # Legacy helpers (for backward compatibility)
  envFile = name: {
    inherit name;
    file = secretFile "${name}.env";
    format = "dotenv";
  };

  yamlSecret = name: key: {
    inherit name key;
    file = secretFile "${name}.yaml";
    format = "yaml";
  };

  # Helper for explicit user-specific secrets (override auto-detection)
  explicitUserSecret = username: secretSpec: secretSpec // {
    owner = username;
    group = "users";
  };

  # Helper for system-wide secrets  
  systemSecret = secretSpec: secretSpec // {
    owner = "root";
    group = "root";
    mode = "0600";
  };

  # Helper for world-readable secrets (use with caution)
  publicSecret = secretSpec: secretSpec // {
    owner = "root";
    group = "root"; 
    mode = "0644";
  };
}
