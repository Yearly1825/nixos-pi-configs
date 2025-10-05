# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

let
  # Read discovery configuration if it exists
  discoveryConfigFile = "/var/lib/nixos-bootstrap/discovery_config.json";
  discoveryConfig =
    if builtins.pathExists discoveryConfigFile then
      builtins.fromJSON (builtins.readFile discoveryConfigFile)
    else
      { hostname = "sensor-pi"; };  # Fallback if file doesn't exist
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      # Import custom modules
      ./modules/discovery-config.nix
      ./modules/boot-notify.nix
    ];

  # Use extlinux bootloader (correct for Raspberry Pi)
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Set wireless regulatory domain for proper WiFi channel access
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=US" ];

  # Disable Raspberry Pi onboard wireless only (keeps USB Wi-Fi/BT working)
  boot.blacklistedKernelModules = [
    "brcmfmac"     # Pi onboard Wi-Fi
    "brcmutil"     # helper for brcmfmac
    "hci_uart"     # Pi onboard Bluetooth (UART attached)
    "btbcm"        # Broadcom BT glue for the Pi
  ];

  # Hostname from discovery service configuration
  networking.hostName = discoveryConfig.hostname or "sensor-pi";

  # Enable DHCP networking (matches hardware config)
  networking.useDHCP = true;

  # Enable SSH access
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "prohibit-password";  # Only allow key-based auth
      PasswordAuthentication = false;  # Disable password auth for security
      PubkeyAuthentication = true;
    };
  };

  # User configuration - enable both nixos and root users
  users.users.nixos = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "dialout" ];  # dialout for GPS access
    initialPassword = "nixos";
  };
  users.users.root = {
    initialPassword = "bootstrap";
    extraGroups = [ "dialout" ];  # dialout for GPS access
  };

  # Basic system packages
  environment.systemPackages = with pkgs; [
    git
    curl
    jq
    wget
    vim
    htop
    tmux
    # Discovery service dependencies
    python3
    python3Packages.requests
    python3Packages.cryptography
    python3Packages.pip

    # Network monitoring tools
    kismet
    aircrack-ng
    hcxdumptool
    hcxtools
    tcpdump
    wireshark-cli  # provides tshark
    nmap
    iftop
    netcat-gnu

    # Additional system tools
    iotop
    nethogs

    # GPS tools
    gpsd
    (python3.withPackages (ps: with ps; [
      gps3
      setuptools
      protobuf
      numpy
    ]))

    # RTL-SDR support
    rtl-sdr
    rtl_433

    # Serial communication
    minicom

    # Wireless tools
    iw
    hostapd-mana
    wpa_supplicant

    # Netbird VPN client
    netbird
  ];

  # Firewall configuration
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22     # SSH
      2501   # Kismet Web UI
    ];
  };

  # Enable discovery configuration service
  services.discovery-config.enable = true;

  # Enable boot notifications via NTFY
  services.boot-notify.enable = true;

  # Enable and configure Netbird VPN using native NixOS module
  services.netbird = {
    enable = true;
    clients.wt0 = {
      autoStart = true;
      port = 51820;
      interface = "wt0";
      openFirewall = true;
      logLevel = "info";
      environment = {
        NB_MANAGEMENT_URL = "https://nb.a28.dev";
        NB_ADMIN_URL = "https://nb.a28.dev";
      };
    };
  };

  # Netbird enrollment service - runs once to authenticate with setup key
  systemd.services.netbird-enroll = {
    description = "Enroll Netbird with setup key from discovery config";
    after = [ "network-online.target" "apply-discovery-config.service" "netbird-wt0.service" ];
    wants = [ "network-online.target" ];
    requires = [ "apply-discovery-config.service" "netbird-wt0.service" ];
    wantedBy = [ "multi-user.target" ];

    # Only run if not already enrolled
    unitConfig = {
      ConditionPathExists = "!/var/lib/netbird-wt0/.enrolled";
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeScript "netbird-enroll.sh" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail

        SETUP_KEY_FILE="/var/lib/netbird-wt0/setup-key"
        ENROLLED_MARKER="/var/lib/netbird-wt0/.enrolled"

        # Wait for setup key from discovery config
        MAX_WAIT=60
        WAITED=0
        while [ ! -f "$SETUP_KEY_FILE" ] && [ $WAITED -lt $MAX_WAIT ]; do
          echo "Waiting for Netbird setup key from discovery config..."
          sleep 5
          WAITED=$((WAITED + 5))
        done

        if [ ! -f "$SETUP_KEY_FILE" ]; then
          echo "Error: Setup key not found at $SETUP_KEY_FILE"
          exit 1
        fi

        SETUP_KEY=$(cat "$SETUP_KEY_FILE")

        if [ -z "$SETUP_KEY" ] || [ "$SETUP_KEY" = "null" ]; then
          echo "Error: Invalid setup key"
          exit 1
        fi

        # Wait for daemon to be ready
        echo "Waiting for Netbird daemon..."
        for i in {1..30}; do
          if ${pkgs.netbird}/bin/netbird --daemon-addr unix:///var/run/netbird-wt0/sock status >/dev/null 2>&1; then
            echo "Netbird daemon ready"
            break
          fi
          sleep 1
        done

        # Enroll with setup key
        echo "Enrolling with Netbird management server..."
        if ${pkgs.netbird}/bin/netbird --daemon-addr unix:///var/run/netbird-wt0/sock up \
          --setup-key "$SETUP_KEY" \
          --management-url "https://nb.a28.dev" \
          --admin-url "https://nb.a28.dev"; then

          echo "Enrollment successful!"
          touch "$ENROLLED_MARKER"
          ${pkgs.netbird}/bin/netbird --daemon-addr unix:///var/run/netbird-wt0/sock status || true
        else
          echo "Enrollment failed, will retry on next boot"
          exit 1
        fi
      '';
      StandardOutput = "journal";
      StandardError = "journal";
      TimeoutStartSec = "300";
      Restart = "on-failure";
      RestartSec = "30s";
      StartLimitBurst = 3;
    };
  };

  # Kismet wireless network monitoring
  # Uses native NixOS module with unprivileged user + capabilities
  # Web UI: http://<ip>:2501 (set password on first login)
  # Logs: /var/lib/kismet/logs/ (rotated hourly via restart timer)
  services.kismet = {
    enable = true;

    # Server identification
    serverName = "Sensor-Monitor";
    serverDescription = "NixOS Pi Sensor Network Monitoring";

    # Web UI configuration
    httpd = {
      enable = true;
      address = "0.0.0.0";
      port = 2501;
    };

    # Log types
    logTypes = [ "kismet" "pcapng" "pcapppi" ];

    # Data directory (same as before)
    dataDir = "/var/lib/kismet";

    # Structured configuration
    settings = {
      # Log configuration with timestamp-based file naming
      log_prefix = "/var/lib/kismet/logs/";
      log_title = "Kismet";
      log_template = "%p/%n-%D-%t-%i.%l";
    };

    # Interface and GPS configuration (using extraConfig for simplicity)
    extraConfig = ''
      # USB Wi-Fi interfaces (4 interfaces on USB hub)
      source=wlp1s0u1u1
      source=wlp1s0u1u2
      source=wlp1s0u1u3
      source=wlp1s0u1u4

      # GPS integration via GPSD
      gps=gpsd:host=localhost,port=2947
    '';
  };

  # Ensure Kismet waits for network and GPSD to be available
  systemd.services.kismet.after = [ "network-online.target" "gpsd.service" ];
  systemd.services.kismet.wants = [ "network-online.target" "gpsd.service" ];

  # Ensure Kismet log directory exists with correct permissions
  systemd.tmpfiles.rules = [
    "d /var/lib/kismet/logs 0755 kismet kismet -"
  ];

  # Timer to restart Kismet every hour for log rotation
  # Creates new timestamped log files on each restart
  systemd.timers.kismet-restart = {
    description = "Restart Kismet hourly for log rotation";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1h";
      OnUnitActiveSec = "1h";
      Unit = "kismet-restart.service";
    };
  };

  # Service to handle the Kismet restart
  systemd.services.kismet-restart = {
    description = "Restart Kismet for log rotation";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart kismet.service";
    };
  };

  # Enable GPS daemon
  services.gpsd = {
    enable = true;
    devices = [ "/dev/ttyUSB1" ];
    nowait = true;
    extraArgs = [ "-n" "-b" ];  # -n = don't wait for client, -b = broken-device-safety
  };

  # Ensure GPSD waits for USB devices to be available
  systemd.services.gpsd.after = [ "systemd-udev-settle.service" ];
  systemd.services.gpsd.serviceConfig.ExecStartPre = "${pkgs.coreutils}/bin/sleep 15";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Match working Pi version
}
