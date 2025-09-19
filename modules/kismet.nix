# Kismet Network Monitoring Module
# Configures Kismet with customizable settings for sensor deployment

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.kismet-sensor;

  # Kismet configuration - written to ~/.kismet/kismet_site.conf
  kismetSiteConf = pkgs.writeText "kismet_site.conf" cfg.extraConfig;

in {
  options.services.kismet-sensor = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Kismet network monitoring";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = ''
        # Logging
        log_prefix=/var/lib/kismet/logs/
        log_title=sensor-%Y-%m-%d-%H-%M-%S
        log_types=kismet

        # Network Interfaces
        #source=wlan0:type=linuxwifi,hop=true,hop_channels="1,2,3,4,5,6,7,8,9,10,11"
        source=wlp1s0u1u1
        source=wlp1s0u1u2
        source=wlp1s0u1u3
        source=wlp1s0u1u4
        # GPS
        gps=gpsd:host=localhost,port=2947

        # Web UI
        #httpd_bind_address=0.0.0.0
        #httpd_port=2501

        # Alerts
        alert=APSPOOF,1/min,5/min,0/min
        alert=CHANCHANGE,1/min,5/min,0/min
        alert=BCASTDISCON,1/min,5/min,0/min

      '';
      example = ''
        # Complete kismet_site.conf content
        #log_prefix=/var/lib/kismet/logs/
        #source=wlan0:type=linuxwifi
        #source=wlan1:type=linuxwifi
      '';
      description = "Complete kismet_site.conf configuration content";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/kismet";
      description = "Directory for Kismet data and logs";
    };
  };

  config = mkIf cfg.enable {
    # Install Kismet and related packages
    environment.systemPackages = with pkgs; [
      kismet
      aircrack-ng
      hcxdumptool
      hcxtools
      tcpdump
      wireshark-cli
      gpsd  # GPS daemon
      rtl-sdr  # RTL-SDR support
      rtl_433  # RTL-433 decoder
      (python3.withPackages (ps: with ps; [
        gps3  # GPS Python tools
        setuptools  # For Python entry points
        protobuf  # For Kismet communication
        numpy  # Often required by capture tools
      ]))
    ];

    # Kismet service
    systemd.services.kismet = {
      description = "Kismet Wireless Network Detector";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        # Use --confdir to specify our config directory with all configs
        ExecStart = "${pkgs.kismet}/bin/kismet --no-ncurses --confdir /root/.kismet";
        Restart = "always";
        RestartSec = "10s";

        # Run as root for interface access
        User = "root";
        Group = "root";

        # Working directory
        WorkingDirectory = cfg.dataDir;

        # Create required directories
        RuntimeDirectory = "kismet";
        StateDirectory = "kismet";
        LogsDirectory = "kismet";
      };

      preStart = ''
        # Ensure data directories exist
        mkdir -p ${cfg.dataDir}/logs
        mkdir -p ${cfg.dataDir}/data

        # Create ~/.kismet directory
        mkdir -p /root/.kismet

        # Link all default Kismet configs to ~/.kismet
        for conf in ${pkgs.kismet}/etc/kismet*.conf; do
          basename=$(basename "$conf")
          if [ ! -e "/root/.kismet/$basename" ]; then
            ln -sf "$conf" "/root/.kismet/$basename"
          fi
        done

        # Write our site config to ~/.kismet/kismet_site.conf
        cp ${kismetSiteConf} /root/.kismet/kismet_site.conf
      '';
    };

    # Open firewall ports for Kismet (default 2501)
    networking.firewall.allowedTCPPorts = [ 2501 ];

    # Create Kismet data directory and config directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root -"
      "d ${cfg.dataDir}/logs 0750 root root -"
      "d ${cfg.dataDir}/data 0750 root root -"
      "d /root/.kismet 0750 root root -"
    ];

    # GPS support is configured in configuration.nix when gps.enable = true
    # This avoids conflicts with the main gpsd service configuration

    # Set wireless regulatory domain for proper channel access
    boot.kernelParams = [ "cfg80211.ieee80211_regdom=US" ];
    hardware.wirelessRegulatoryDatabase = true;
  };
}
