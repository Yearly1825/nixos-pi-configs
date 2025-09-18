# Netbird VPN Module
# Configures Netbird to auto-connect using setup key from discovery service

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.netbird-sensor;

  # Netbird setup and enrollment script
  setupNetbird = pkgs.writeScriptBin "setup-netbird" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    SETUP_KEY_FILE="/var/lib/netbird/setup-key"
    ENROLLED_MARKER="/var/lib/netbird/.enrolled"
    MANAGEMENT_URL="${cfg.managementUrl}"

    # Check if already enrolled
    if [ -f "$ENROLLED_MARKER" ]; then
      echo "Netbird already enrolled"
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

    echo "Installing Netbird service..."

    # First, uninstall any existing service
    ${pkgs.netbird}/bin/netbird service uninstall 2>/dev/null || true

    # Install the service with proper parameters
    ${pkgs.netbird}/bin/netbird service install \
      --config /var/lib/netbird/config.json \
      --log-file console

    echo "Starting Netbird service..."
    ${pkgs.netbird}/bin/netbird service start || {
      echo "Failed to start service via netbird, trying systemctl..."
      ${pkgs.systemd}/bin/systemctl start netbird || true
    }

    # Wait for service to be running
    sleep 5

    echo "Enrolling with setup key..."
    ${pkgs.netbird}/bin/netbird up \
      --setup-key "$SETUP_KEY" \
      --management-url "$MANAGEMENT_URL" || {
        echo "Enrollment failed, will retry on next boot"
        exit 1
      }

    echo "Netbird enrollment successful"
    touch "$ENROLLED_MARKER"

    # Show status
    ${pkgs.netbird}/bin/netbird status || true
  '';

  # Auto-connect script for already enrolled devices
  autoConnectNetbird = pkgs.writeScriptBin "auto-connect-netbird" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

    ENROLLED_MARKER="/var/lib/netbird/.enrolled"

    if [ ! -f "$ENROLLED_MARKER" ]; then
      echo "Device not enrolled, skipping auto-connect"
      exit 0
    fi

    # Check if daemon is running
    if ! ${pkgs.netbird}/bin/netbird status >/dev/null 2>&1; then
      echo "Netbird daemon not running, starting..."
      ${pkgs.netbird}/bin/netbird service start 2>/dev/null || \
        ${pkgs.systemd}/bin/systemctl start netbird || true
      sleep 3
    fi

    # Try to connect
    echo "Connecting to Netbird network..."
    ${pkgs.netbird}/bin/netbird up || {
      echo "Connection failed, will retry"
      exit 1
    }

    echo "Netbird connected successfully"
    ${pkgs.netbird}/bin/netbird status
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

    # Setup service - handles installation and enrollment
    systemd.services.netbird-setup = {
      description = "Setup and enroll Netbird";
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
        ExecStart = "${setupNetbird}/bin/setup-netbird";
        StandardOutput = "journal";
        StandardError = "journal";

        # Give it time to complete
        TimeoutStartSec = "300";

        # Don't retry - we'll try again on next boot if needed
        Restart = "no";
      };
    };

    # Auto-connect service for already enrolled devices
    systemd.services.netbird-autoconnect = mkIf cfg.autoConnect {
      description = "Auto-connect Netbird VPN";
      after = [ "network-online.target" "netbird-setup.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      # Only run if already enrolled
      unitConfig = {
        ConditionPathExists = "/var/lib/netbird/.enrolled";
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${autoConnectNetbird}/bin/auto-connect-netbird";
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
