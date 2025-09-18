# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

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

  # Hostname will be set dynamically from discovery service
  # networking.hostName = "sensor-pi";  # Commented out - set by discovery-config

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
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "nixos";
  };
  users.users.root.initialPassword = "bootstrap";

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

    # Example: Monitor wlan0 interface (uncomment and modify as needed)
    # interfaces = [ "wlan0:type=linuxwifi,hop=true" ];

    # Web UI configuration
    httpd = {
      bindAddress = "0.0.0.0";  # Listen on all interfaces
      port = 2501;
      username = "kismet";
      password = "changeme";  # Change this in production!
    };

    # Example GPS configuration (uncomment if you have GPS)
    # gps = {
    #   enable = true;
    #   host = "127.0.0.1";
    #   port = 2947;
    # };

    # Additional custom Kismet configuration
    extraConfig = ''
      # Add any custom Kismet configuration here
      # Example: source=wlan1:type=linuxwifi,hop=true,hop_channels="1,6,11"
      # Example: alert=APSPOOF,1/min,5/min,0/min
    '';
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It's perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Match working Pi version
}
