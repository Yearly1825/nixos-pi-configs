# Boot Notification Module
# Sends NTFY notification on every boot with system information and all network IPs

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-notify;

  # Script to send boot notification
  bootNotifyScript = pkgs.writeShellScriptBin "boot-notify" ''
    set -euo pipefail

    # Wait for VPN interface to have an IP address (max 30 seconds)
    echo "Waiting for VPN interface wt0..."
    VPN_TIMEOUT=30
    VPN_ELAPSED=0
    while [ $VPN_ELAPSED -lt $VPN_TIMEOUT ]; do
      # Check if wt0 exists and has an IP address
      if ${pkgs.iproute2}/bin/ip addr show wt0 2>/dev/null | grep -q "inet "; then
        echo "VPN interface wt0 is up with IP address"
        break
      fi
      sleep 1
      VPN_ELAPSED=$((VPN_ELAPSED + 1))
    done

    if [ $VPN_ELAPSED -ge $VPN_TIMEOUT ]; then
      echo "Warning: VPN interface did not come up within ${VPN_TIMEOUT} seconds, proceeding anyway"
    fi

    NTFY_CONFIG="/var/lib/sensor-ntfy/config.json"

    # Exit gracefully if no NTFY config exists
    if [ ! -f "$NTFY_CONFIG" ]; then
      echo "No NTFY config found at $NTFY_CONFIG, skipping notification"
      exit 0
    fi

    echo "Reading NTFY configuration..."

    # Parse NTFY config
    URL=$(${pkgs.jq}/bin/jq -r '.url // empty' "$NTFY_CONFIG")
    AUTH_TYPE=$(${pkgs.jq}/bin/jq -r '.auth_type // "none"' "$NTFY_CONFIG")
    PRIORITY=$(${pkgs.jq}/bin/jq -r '.priority // "default"' "$NTFY_CONFIG")
    TAGS=$(${pkgs.jq}/bin/jq -r '.tags // [] | join(",")' "$NTFY_CONFIG")

    # Exit if no URL configured
    if [ -z "$URL" ] || [ "$URL" = "null" ]; then
      echo "No NTFY URL configured, skipping notification"
      exit 0
    fi

    echo "Gathering system information..."

    # Gather system information
    HOSTNAME=$(${pkgs.nettools}/bin/hostname)
    UPTIME=$(${pkgs.procps}/bin/uptime -p)
    KERNEL=$(${pkgs.coreutils}/bin/uname -r)

    # Get all network interfaces with their IPv4 addresses
    # Format: "  eth0: 192.168.1.100"
    IP_INFO=$(${pkgs.iproute2}/bin/ip -4 addr show | ${pkgs.gawk}/bin/awk '
      /^[0-9]+: / {
        iface = $2
        gsub(/:/, "", iface)
        next
      }
      /inet / && iface !~ /^lo$/ {
        ip = $2
        gsub(/\/.*/, "", ip)
        printf "  %s: %s\n", iface, ip
      }
    ')

    # Get Netbird VPN status if available
    NETBIRD_STATUS="Unknown"
    if command -v netbird >/dev/null 2>&1; then
      if ${pkgs.netbird}/bin/netbird --daemon-addr unix:///var/run/netbird-wt0/sock status >/dev/null 2>&1; then
        NETBIRD_STATUS="Connected"
      else
        NETBIRD_STATUS="Disconnected"
      fi
    fi

    # Build notification message
    MESSAGE="🚀 Sensor Boot Complete

Hostname: $HOSTNAME
Kernel: $KERNEL
Uptime: $UPTIME

Network Interfaces:
$IP_INFO

VPN Status: $NETBIRD_STATUS

✅ System ready for SSH access"

    echo "Sending boot notification to NTFY..."

    # Build curl authentication based on auth type
    AUTH_ARGS=""
    if [ "$AUTH_TYPE" = "basic" ]; then
      USERNAME=$(${pkgs.jq}/bin/jq -r '.username // empty' "$NTFY_CONFIG")
      PASSWORD=$(${pkgs.jq}/bin/jq -r '.password // empty' "$NTFY_CONFIG")
      if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
        AUTH_ARGS="-u $USERNAME:$PASSWORD"
      fi
    elif [ "$AUTH_TYPE" = "bearer" ]; then
      TOKEN=$(${pkgs.jq}/bin/jq -r '.token // empty' "$NTFY_CONFIG")
      if [ -n "$TOKEN" ]; then
        AUTH_ARGS="-H \"Authorization: Bearer $TOKEN\""
      fi
    fi

    # Send notification with retry logic
    if eval ${pkgs.curl}/bin/curl -X POST "\"$URL\"" \
      $AUTH_ARGS \
      -H "\"Title: 🖥️ $HOSTNAME - Boot Complete\"" \
      -H "\"Priority: $PRIORITY\"" \
      -H "\"Tags: $TAGS\"" \
      -d "\"$MESSAGE\"" \
      --max-time 10 \
      --retry 3 \
      --retry-delay 5 \
      --silent \
      --show-error; then
      echo "✅ Boot notification sent successfully"
    else
      echo "⚠️  Failed to send boot notification (non-fatal)"
    fi
  '';

in {
  options.services.boot-notify = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable boot notification via NTFY";
    };
  };

  config = mkIf cfg.enable {
    # Boot notification service
    systemd.services.boot-notify = {
      description = "Send boot notification via NTFY";

      # Wait for network and critical services
      after = [
        "network-online.target"
        "apply-discovery-config.service"  # Ensures NTFY config is available
        "netbird-wt0.service"             # Wait for VPN to be up
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${bootNotifyScript}/bin/boot-notify";
        StandardOutput = "journal";
        StandardError = "journal";

        # Don't block boot if notification fails
        RemainAfterExit = true;
        Restart = "no";

        # Timeout after 30 seconds
        TimeoutStartSec = "30s";
      };
    };

    # Ensure NTFY config directory exists
    systemd.tmpfiles.rules = [
      "d /var/lib/sensor-ntfy 0700 root root -"
    ];
  };
}
