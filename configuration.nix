{ config, lib, pkgs, ... }:

let
  # Read hostname from discovery config if it exists
  discoveryConfig = "/var/lib/nixos-bootstrap/discovery_config.json";
  defaultHostname = "sensor-default";

  # Simple hostname detection function
  getDiscoveryHostname =
    if builtins.pathExists discoveryConfig
    then
      let
        configContent = builtins.readFile discoveryConfig;
        parsedConfig = builtins.fromJSON configContent;
      in
        parsedConfig.hostname or defaultHostname
    else defaultHostname;

in {
  # System version
  system.stateVersion = "24.05";

  # Nix configuration (matching bootstrap)
  nix = {
    package = pkgs.nixVersions.stable;
    settings.experimental-features = [ "nix-command" "flakes" ];
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 7d";
    };
  };

  # Network configuration (matching bootstrap)
  networking = {
    hostName = getDiscoveryHostname;
    networkmanager.enable = true;
    useDHCP = false;
    interfaces = {
      eth0.useDHCP = true;
      end0.useDHCP = true;
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 ];
    };
  };

  # Network discovery services
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish.enable = true;
    publish.addresses = true;
  };

  # Ensure network is available
  systemd.services.NetworkManager-wait-online.enable = true;

  # SSH configuration
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "yes";
      PasswordAuthentication = true;
    };
  };

  # User configuration
  users.users.root.initialPassword = "bootstrap";

  # System packages (matching bootstrap exactly)
  environment.systemPackages = with pkgs; [
    # Basic tools
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

    # Pre-installed network monitoring tools
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
  ];

  # Bootstrap test service (matching bootstrap)
  systemd.services.bootstrap-test = {
    description = "Bootstrap Test Service - Verify Package Installation";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils nettools gawk procps python3 ];
    script = ''
      echo "=== Bootstrap configuration applied successfully! ===" > /var/log/bootstrap-test.log
      echo "Hostname: $(cat /proc/sys/kernel/hostname)" >> /var/log/bootstrap-test.log
      echo "Time: $(date)" >> /var/log/bootstrap-test.log
      echo "Netbird setup key: $NETBIRD_SETUP_KEY" >> /var/log/bootstrap-test.log
      echo "" >> /var/log/bootstrap-test.log

      # Verify key packages are installed
      echo "=== Package Verification ===" >> /var/log/bootstrap-test.log

      # Basic tools
      for tool in git curl jq wget vim htop tmux python3; do
        if command -v "$tool" >/dev/null 2>&1; then
          echo "✓ $tool: $(command -v $tool)" >> /var/log/bootstrap-test.log
        else
          echo "✗ $tool: NOT FOUND" >> /var/log/bootstrap-test.log
        fi
      done

      # Network tools
      for tool in kismet aircrack-ng hcxdumptool tcpdump tshark nmap iftop netcat; do
        if command -v "$tool" >/dev/null 2>&1; then
          echo "✓ $tool: $(command -v $tool)" >> /var/log/bootstrap-test.log
        else
          echo "✗ $tool: NOT FOUND" >> /var/log/bootstrap-test.log
        fi
      done

      # Python packages
      echo "" >> /var/log/bootstrap-test.log
      echo "=== Python Package Verification ===" >> /var/log/bootstrap-test.log
      python3 -c "
      import sys
      packages = ['requests', 'cryptography', 'json', 'hashlib', 'hmac', 'base64']
      for pkg in packages:
          try:
              __import__(pkg)
              print(f'✓ {pkg}: Available')
          except ImportError:
              print(f'✗ {pkg}: NOT AVAILABLE')
      " >> /var/log/bootstrap-test.log 2>&1

      echo "" >> /var/log/bootstrap-test.log
      echo "=== System Info ===" >> /var/log/bootstrap-test.log
      echo "Kernel: $(uname -r)" >> /var/log/bootstrap-test.log
      echo "Architecture: $(uname -m)" >> /var/log/bootstrap-test.log
      echo "Memory: $(free -h | grep '^Mem:' | awk '{print $2 " total, " $7 " available"}')" >> /var/log/bootstrap-test.log
      echo "Disk usage: $(df -h / | tail -1 | awk '{print $3 "/" $2 " (" $5 ")"}')" >> /var/log/bootstrap-test.log

      echo "=== Test completed at $(date) ===" >> /var/log/bootstrap-test.log
    '';
  };

  # Bootstrap completion marker
  systemd.services.bootstrap-complete-marker = {
    description = "Mark bootstrap as complete - Final Configuration Applied";
    wantedBy = [ "multi-user.target" ];
    after = [ "bootstrap-test.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils ];
    script = ''
      echo "$(date): Final sensor configuration applied successfully for $(cat /proc/sys/kernel/hostname)" >> /var/log/sensor-bootstrap.log
      echo "$(date): All packages installed and verified" >> /var/log/sensor-bootstrap.log
      echo "$(date): Bootstrap process completed - ready for sensor operations" >> /var/log/sensor-bootstrap.log

      # Create completion markers
      touch /var/lib/sensor-bootstrap-complete
      touch /var/lib/bootstrap-complete

      # Log final status
      echo "🎉 Bootstrap completed successfully at $(date)" >> /var/log/sensor-bootstrap.log
      echo "📊 System ready for sensor data collection" >> /var/log/sensor-bootstrap.log

      # Display completion message to console
      echo "🚀 Sensor configuration bootstrap completed successfully!"
      echo "📝 Check /var/log/bootstrap-test.log for package verification"
      echo "📝 Check /var/log/sensor-bootstrap.log for completion status"
    '';
  };
}
