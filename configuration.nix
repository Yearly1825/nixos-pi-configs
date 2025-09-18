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
      ./modules/netbird.nix
      ./modules/kismet.nix
    ];

  # Use extlinux bootloader (correct for Raspberry Pi)
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Set wireless regulatory domain for proper WiFi channel access
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=US" ];

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

    # Pre-installed network monitoring tools (speeds up bootstrap)
    kismet
    aircrack-ng
    hcxdumptool
    hcxtools
    tcpdump
    wireshark-cli  # provides tshark
    nmap
    iftop
    netcat-gnu

    # GPS support
    gpsd

    # Additional system tools
    iotop
    nethogs

    # GPS tools
    gpsd
    (python3.withPackages (ps: with ps; [ gps3 ]))

    # Netbird troubleshooting helper scripts
    (pkgs.writeScriptBin "netbird-fix" ''
      #!${pkgs.bash}/bin/bash
      echo "=== Netbird Troubleshooting ==="

      echo "Restarting Netbird daemon..."
      systemctl restart netbird
      sleep 3

      echo "Checking daemon status..."
      systemctl status netbird --no-pager

      echo ""
      echo "Checking Netbird connection..."
      netbird status || echo "Not connected yet"

      echo ""
      echo "If not connected, run: netbird-enroll"
    '')

    (pkgs.writeScriptBin "netbird-enroll" ''
      #!${pkgs.bash}/bin/bash
      SETUP_KEY_FILE="/var/lib/netbird/setup-key"
      ENROLLED_MARKER="/var/lib/netbird/.enrolled"

      # Check if already enrolled
      if [ -f "$ENROLLED_MARKER" ]; then
        echo "Already enrolled, trying to connect..."
        netbird up
        exit 0
      fi

      if [ -f "$SETUP_KEY_FILE" ]; then
        SETUP_KEY=$(cat "$SETUP_KEY_FILE")
        echo "Enrolling with setup key..."
        if netbird up --setup-key "$SETUP_KEY" --management-url https://nb.a28.dev; then
          touch "$ENROLLED_MARKER"
          echo "Enrollment successful!"
          netbird status
        else
          echo "Enrollment failed"
          exit 1
        fi
      else
        echo "No setup key found at $SETUP_KEY_FILE"
        echo "Run: systemctl status apply-discovery-config"
        exit 1
      fi
    '')

    (pkgs.writeScriptBin "sensor-status" ''
      #!${pkgs.bash}/bin/bash
      echo "=== Sensor Status ==="
      echo "Hostname: $(hostname)"
      echo "Discovery Config:"
      cat /var/lib/nixos-bootstrap/discovery_config.json 2>/dev/null | jq . || echo "Not found"
      echo ""
      echo "=== Netbird Status ==="
      netbird status 2>/dev/null || echo "Not running"
      echo ""
      echo "=== Services ==="
      systemctl is-active apply-discovery-config netbird netbird-enroll netbird-autoconnect kismet
    '')

    (pkgs.writeScriptBin "gps-check" ''
      #!${pkgs.bash}/bin/bash
      echo "=== GPS Troubleshooting ==="
      echo ""
      echo "1. Checking for GPS devices:"
      ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || echo "No USB GPS devices found"

      echo ""
      echo "2. GPSD service status:"
      systemctl status gpsd --no-pager

      echo ""
      echo "3. GPSD socket:"
      ls -la /var/run/gpsd* 2>/dev/null || echo "No GPSD socket found"

      echo ""
      echo "4. Testing GPSD connection:"
      timeout 2 gpspipe -r -n 5 2>/dev/null || echo "Could not connect to GPSD"

      echo ""
      echo "5. Available GPS tools:"
      which cgps gpsmon gpspipe

      echo ""
      echo "Tips:"
      echo "- Make sure GPS device is plugged into USB"
      echo "- Common devices: /dev/ttyUSB0, /dev/ttyACM0"
      echo "- Restart GPSD: systemctl restart gpsd"
      echo "- Monitor GPS: cgps or gpsmon"
    '')
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

  # Enable and configure Netbird VPN
  services.netbird-sensor = {
    enable = true;
    managementUrl = "https://nb.a28.dev";
    autoConnect = true;
  };

  # Enable and configure Kismet
  services.kismet-sensor = {
    enable = true;

    # Override the entire kismet_site.conf if needed
    # The default config is defined in the module
    # Uncomment below to override with your custom configuration:

    # extraConfig = ''
    #   log_prefix=/var/lib/kismet/logs/
    #   log_title=sensor-%Y-%m-%d-%H-%M-%S
    #
    #   source=wlan0:type=linuxwifi,hop=true
    #   source=wlan1:type=linuxwifi,hop=true
    #
    #   httpd_bind_address=0.0.0.0
    #   httpd_port=2501
    #   httpd_username=admin
    #   httpd_password=changeme
    # '';
  };

  # Enable GPS daemon
  services.gpsd = {
    enable = true;
    devices = [ "/dev/ttyUSB0" "/dev/ttyACM0" ];
    nowait = true;
    extraArgs = [ "-n" "-b" ];  # -n = don't wait for client, -b = broken-device-safety
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Match working Pi version
}
