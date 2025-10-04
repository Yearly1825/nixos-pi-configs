# Discovery Configuration Module
# Reads configuration from discovery service and applies hostname, SSH keys, etc.

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.discovery-config;

  # Script to read and apply discovery configuration
  applyDiscoveryConfig = pkgs.writeScriptBin "apply-discovery-config" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    CONFIG_FILE="/var/lib/nixos-bootstrap/discovery_config.json"

    if [ ! -f "$CONFIG_FILE" ]; then
      echo "Warning: Discovery config file not found at $CONFIG_FILE"
      exit 0
    fi

    # Note: Hostname is set declaratively in NixOS configuration, not dynamically
    # The hostname from discovery service is stored in the JSON but applied via configuration.nix

    # Apply SSH keys
    echo "Applying SSH keys from discovery configuration..."
    ${pkgs.jq}/bin/jq -r '.ssh_keys[]' "$CONFIG_FILE" > /tmp/discovery_ssh_keys 2>/dev/null || true

    if [ -s /tmp/discovery_ssh_keys ]; then
      # Ensure SSH directory exists for root
      mkdir -p /root/.ssh
      chmod 700 /root/.ssh

      # Add keys to authorized_keys (avoiding duplicates)
      touch /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys

      while IFS= read -r key; do
        if ! grep -Fxq "$key" /root/.ssh/authorized_keys 2>/dev/null; then
          echo "$key" >> /root/.ssh/authorized_keys
          echo "Added SSH key: $(echo "$key" | cut -d' ' -f1-2)"
        fi
      done < /tmp/discovery_ssh_keys

      # Also add to nixos user if exists
      if id -u nixos >/dev/null 2>&1; then
        mkdir -p /home/nixos/.ssh
        chmod 700 /home/nixos/.ssh
        chown nixos:users /home/nixos/.ssh

        touch /home/nixos/.ssh/authorized_keys
        chmod 600 /home/nixos/.ssh/authorized_keys
        chown nixos:users /home/nixos/.ssh/authorized_keys

        while IFS= read -r key; do
          if ! grep -Fxq "$key" /home/nixos/.ssh/authorized_keys 2>/dev/null; then
            echo "$key" >> /home/nixos/.ssh/authorized_keys
          fi
        done < /tmp/discovery_ssh_keys
      fi

      rm -f /tmp/discovery_ssh_keys
      echo "SSH keys applied successfully"
    else
      echo "No SSH keys found in discovery configuration"
    fi

    # Save Netbird setup key to a secure location for the netbird service to use
    NETBIRD_KEY=$(${pkgs.jq}/bin/jq -r '.netbird_setup_key' "$CONFIG_FILE")
    if [ -n "$NETBIRD_KEY" ] && [ "$NETBIRD_KEY" != "null" ]; then
      mkdir -p /var/lib/netbird-wt0
      echo "$NETBIRD_KEY" > /var/lib/netbird-wt0/setup-key
      chmod 600 /var/lib/netbird-wt0/setup-key
      echo "Netbird setup key saved"
    fi

    # Save NTFY configuration for boot notifications
    echo "Extracting NTFY configuration..."
    NTFY_CONFIG=$(${pkgs.jq}/bin/jq -c '.ntfy_config' "$CONFIG_FILE" 2>/dev/null || echo "null")

    if [ -n "$NTFY_CONFIG" ] && [ "$NTFY_CONFIG" != "null" ]; then
      mkdir -p /var/lib/sensor-ntfy
      echo "$NTFY_CONFIG" > /var/lib/sensor-ntfy/config.json
      chmod 600 /var/lib/sensor-ntfy/config.json
      echo "NTFY configuration saved to /var/lib/sensor-ntfy/config.json"
    else
      echo "No NTFY configuration found in discovery config"
    fi

    echo "Discovery configuration applied successfully"
  '';

in {
  options.services.discovery-config = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable discovery configuration service";
    };
  };

  config = mkIf cfg.enable {
    # Create systemd service to apply discovery config on boot
    systemd.services.apply-discovery-config = {
      description = "Apply configuration from discovery service";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Run before SSH and other services that might need the config
      before = [ "sshd.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${applyDiscoveryConfig}/bin/apply-discovery-config";
        StandardOutput = "journal";
        StandardError = "journal";
      };
    };

    # Ensure directories exist for netbird and sensor-ntfy
    systemd.tmpfiles.rules = [
      "d /var/lib/netbird-wt0 0700 root root -"
      "d /var/lib/sensor-ntfy 0700 root root -"
    ];
  };
}
