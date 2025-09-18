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

    # Check if already enrolled
    if [ -f "$ENROLLED_MARKER" ]; then
      echo "Netbird already enrolled, checking connection..."
      if ${pkgs.netbird}/bin/netbird status >/dev/null 2>&1; then
        echo "Netbird is connected"
        exit 0
      else
        echo "Netbird enrolled but not connected, attempting to connect..."
        ${pkgs.netbird}/bin/netbird up
        exit 0
      fi
    fi

    # Wait for setup key file
    MAX_WAIT=60
    WAITED=0
    while [ ! -f "$SETUP_KEY_FILE" ] && [ $WAITED -lt $MAX_WAIT ]; do
      echo "Waiting for Netbird setup key from discovery config..."
      sleep 5
      WAITED=$((WAITED + 5))
    done

    if [ ! -f "$SETUP_KEY_FILE" ]; then
      echo "Warning: Netbird setup key not found at $SETUP_KEY_FILE"
      exit 1
    fi

    SETUP_KEY=$(cat "$SETUP_KEY_FILE")

    if [ -z "$SETUP_KEY" ] || [ "$SETUP_KEY" = "null" ]; then
      echo "Error: Invalid setup key"
      exit 1
    fi

    echo "Enrolling Netbird with management URL: $MANAGEMENT_URL"

    # Enroll with Netbird
    if ${pkgs.netbird}/bin/netbird up \
        --setup-key "$SETUP_KEY" \
        --management-url "$MANAGEMENT_URL"; then

      echo "Netbird enrollment successful"
      touch "$ENROLLED_MARKER"

      # Ensure Netbird starts on boot
      ${pkgs.systemd}/bin/systemctl enable netbird

      # Get status
      ${pkgs.netbird}/bin/netbird status
    else
      echo "Netbird enrollment failed"
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

    # Netbird service for auto-connection
    systemd.services.netbird = {
      description = "Netbird VPN Client";
      after = [ "network-online.target" "apply-discovery-config.service" ];
      wants = [ "network-online.target" ];
      requires = [ "apply-discovery-config.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "notify";
        ExecStart = "${pkgs.netbird}/bin/netbird service run";
        Restart = "always";
        RestartSec = "5s";

        # Run as root for network configuration
        User = "root";
        Group = "root";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/netbird" ];

        # Capabilities needed for network configuration
        AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" "CAP_NET_BIND_SERVICE" ];
      };
    };

    # Enrollment service (one-time)
    systemd.services.netbird-enroll = {
      description = "Enroll Netbird with setup key";
      after = [ "network-online.target" "apply-discovery-config.service" ];
      wants = [ "network-online.target" ];
      requires = [ "apply-discovery-config.service" ];
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

        # Retry on failure
        Restart = "on-failure";
        RestartSec = "30s";
        StartLimitBurst = 5;
      };
    };

    # Auto-connect service for subsequent boots
    systemd.services.netbird-autoconnect = mkIf cfg.autoConnect {
      description = "Auto-connect Netbird VPN";
      after = [ "netbird.service" ];
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

        # Retry connection
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitBurst = 3;
      };
    };

    # Ensure netbird directory exists with proper permissions
    systemd.tmpfiles.rules = [
      "d /var/lib/netbird 0700 root root -"
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
