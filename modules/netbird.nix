# Netbird VPN Module
# Configures Netbird to auto-connect using setup key from discovery service

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.netbird-sensor;

  # Netbird enrollment script
  enrollNetbird = pkgs.writeScriptBin "enroll-netbird" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    SETUP_KEY_FILE="/var/lib/netbird/setup-key"
    ENROLLED_MARKER="/var/lib/netbird/.enrolled"
    MANAGEMENT_URL="${cfg.managementUrl}"
    CONFIG_FILE="/var/lib/netbird/config.json"

    # Check if already enrolled
    if [ -f "$ENROLLED_MARKER" ]; then
      echo "Netbird already enrolled"
      # Try to connect if not connected
      ${pkgs.netbird}/bin/netbird up 2>/dev/null || true
      exit 0
    fi

    # Wait for setup key file from discovery config
    MAX_WAIT=60
    WAITED=0
    while [ ! -f "$SETUP_KEY_FILE" ] && [ $WAITED -lt $MAX_WAIT ]; do
      echo "Waiting for Netbird setup key from discovery config..."
      sleep 5
      WAITED=$((WAITED + 5))
    done

    if [ ! -f "$SETUP_KEY_FILE" ]; then
      echo "Error: Netbird setup key not found at $SETUP_KEY_FILE"
      echo "Make sure discovery config has run successfully"
      exit 1
    fi

    SETUP_KEY=$(cat "$SETUP_KEY_FILE")

    if [ -z "$SETUP_KEY" ] || [ "$SETUP_KEY" = "null" ]; then
      echo "Error: Invalid setup key"
      exit 1
    fi

    echo "Waiting for Netbird daemon to be ready..."
    for i in {1..30}; do
      if ${pkgs.netbird}/bin/netbird status >/dev/null 2>&1; then
        echo "Netbird daemon is ready"
        break
      fi
      sleep 1
    done

    echo "Enrolling with setup key..."
    if ${pkgs.netbird}/bin/netbird up \
      --setup-key "$SETUP_KEY" \
      --management-url "$MANAGEMENT_URL" \
      --admin-url "$MANAGEMENT_URL"; then

      echo "Netbird enrollment successful"
      touch "$ENROLLED_MARKER"

      # Show status
      ${pkgs.netbird}/bin/netbird status || true
    else
      echo "Enrollment failed, will retry on next boot"
      exit 1
    fi
  '';

in {
  options.services.netbird-sensor = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Netbird VPN for sensor";
    };

    managementUrl = mkOption {
      type = types.str;
      default = "https://nb.a28.dev";
      description = "Netbird management URL";
    };

    autoConnect = mkOption {
      type = types.bool;
      default = true;
      description = "Automatically connect on boot";
    };
  };

  config = mkIf cfg.enable {
    # Install Netbird package
    environment.systemPackages = [ pkgs.netbird ];

    # Netbird daemon service - NixOS managed
    systemd.services.netbird = {
      description = "Netbird VPN Client Daemon";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.netbird}/bin/netbird service run --config /var/lib/netbird/config.json --log-level info";
        Restart = "always";
        RestartSec = "5s";

        # Run as root for network configuration
        User = "root";
        Group = "root";

        # Working directory
        WorkingDirectory = "/var/lib/netbird";

        # Security settings
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/netbird" "/var/run/netbird" ];

        # Network capabilities
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_BIND_SERVICE" "CAP_NET_RAW" ];
      };

      preStart = ''
        # Ensure directories exist
        mkdir -p /var/lib/netbird /var/run/netbird

        # Create default config if it doesn't exist
        if [ ! -f /var/lib/netbird/config.json ]; then
          echo '{}' > /var/lib/netbird/config.json
        fi
      '';
    };

    # Enrollment service - handles initial enrollment
    systemd.services.netbird-enroll = {
      description = "Enroll Netbird with setup key";
      after = [ "network-online.target" "apply-discovery-config.service" "netbird.service" ];
      wants = [ "network-online.target" ];
      requires = [ "apply-discovery-config.service" "netbird.service" ];
      wantedBy = [ "multi-user.target" ];

      # Only run if not already enrolled
      unitConfig = {
        ConditionPathExists = "!/var/lib/netbird/.enrolled";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${enrollNetbird}/bin/enroll-netbird";
        StandardOutput = "journal";
        StandardError = "journal";

        # Give it time to complete
        TimeoutStartSec = "300";

        # Retry on failure
        Restart = "on-failure";
        RestartSec = "30s";
        StartLimitBurst = 3;
      };
    };

    # Auto-connect service for already enrolled devices
    systemd.services.netbird-autoconnect = mkIf cfg.autoConnect {
      description = "Auto-connect Netbird VPN";
      after = [ "network-online.target" "netbird.service" ];
      requires = [ "netbird.service" ];
      wantedBy = [ "multi-user.target" ];

      # Only run if already enrolled
      unitConfig = {
        ConditionPathExists = "/var/lib/netbird/.enrolled";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.netbird}/bin/netbird up || true'";
        StandardOutput = "journal";
        StandardError = "journal";

        # Retry on failure
        Restart = "on-failure";
        RestartSec = "30s";
        StartLimitBurst = 3;
      };
    };

    # Ensure netbird directories exist with proper permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/netbird 0755 root root -"
      "d /var/run/netbird 0755 root root -"
      "d /var/log/netbird 0755 root root -"
    ];

    # Open firewall for Netbird
    networking.firewall = {
      # Netbird uses WireGuard protocol on UDP port 51820 by default
      allowedUDPPorts = [ 51820 ];

      # Allow Netbird interface
      trustedInterfaces = [ "wt0" ];  # Netbird default interface
    };
  };
}
