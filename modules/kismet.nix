# Kismet Network Monitoring Module
# Configures Kismet with customizable settings for sensor deployment

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.kismet-sensor;

  # Minimal Kismet configuration - only overrides from defaults
  kismetSiteConf = pkgs.writeText "kismet_site.conf" ''
    # Kismet Site Configuration - Minimal overrides only
    # Most settings use Kismet defaults

    # Logging
    log_prefix=/var/lib/kismet/logs/
    log_title=sensor-%Y-%m-%d-%H-%M-%S
    log_types=kismet,pcapng

    # Network Interfaces
    ${concatStringsSep "\n" (map (iface: "source=${iface}") cfg.interfaces)}

    # GPS
    ${optionalString cfg.gps.enable ''
    gps=true
    gpshost=${cfg.gps.host}
    gpsport=${toString cfg.gps.port}
    ''}

    # Web UI
    httpd_bind_address=${cfg.httpd.bindAddress}
    httpd_port=${toString cfg.httpd.port}
    httpd_username=${cfg.httpd.username}
    httpd_password=${cfg.httpd.password}

    # User overrides
    ${cfg.extraConfig}
  '';

in {
  options.services.kismet-sensor = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Kismet network monitoring";
    };

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ "wlan0:type=linuxwifi,hop=true,hop_channels=\"1,2,3,4,5,6,7,8,9,10,11\"" ];
      example = [ "wlan0:type=linuxwifi" "wlan1:type=linuxwifi,hop=true" ];
      description = "Network interfaces to monitor";
    };

    gps = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable GPS support via gpsd";
      };

      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "GPSD host";
      };

      port = mkOption {
        type = types.port;
        default = 2947;
        description = "GPSD port";
      };
    };

    httpd = {
      bindAddress = mkOption {
        type = types.str;
        default = "0.0.0.0";
        description = "HTTP server bind address";
      };

      port = mkOption {
        type = types.port;
        default = 2501;
        description = "HTTP server port";
      };

      allowedHosts = mkOption {
        type = types.str;
        default = "*";
        description = "Allowed hosts for HTTP connections";
      };

      username = mkOption {
        type = types.str;
        default = "admin";
        description = "Web UI username";
      };

      password = mkOption {
        type = types.str;
        default = "sensor123!";
        description = "Web UI password";
      };
    };

    extraConfig = mkOption {
      type = types.lines;
      default = ''
        # Alerts
        alert=APSPOOF,1/min,5/min,0/min
        alert=CHANCHANGE,1/min,5/min,0/min
        alert=BCASTDISCON,1/min,5/min,0/min

        # Performance tuning for Raspberry Pi
        packet_dedup_size=2048
        packet_backlog_warning=512
        packet_backlog_limit=1024
        tracker_device_timeout=600
      '';
      example = ''
        # Additional custom configuration
        source=rtl433-0:type=rtl433,device=0
        alert=APSPOOF,1/min,5/min,0/min
      '';
      description = "Extra configuration to append to kismet_site.conf";
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
      (python3.withPackages (ps: with ps; [ gps3 ]))  # GPS Python tools
    ];

    # Kismet service
    systemd.services.kismet = {
      description = "Kismet Wireless Network Detector";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.kismet}/bin/kismet --no-ncurses -f ${kismetSiteConf}";
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
      '';
    };

    # Open firewall ports for Kismet
    networking.firewall.allowedTCPPorts = [ cfg.httpd.port ];

    # Create Kismet data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 root root -"
      "d ${cfg.dataDir}/logs 0750 root root -"
      "d ${cfg.dataDir}/data 0750 root root -"
    ];

    # GPS support is configured in configuration.nix when gps.enable = true
    # This avoids conflicts with the main gpsd service configuration

    # Set wireless regulatory domain for proper channel access
    boot.kernelParams = [ "cfg80211.ieee80211_regdom=US" ];
    hardware.wirelessRegulatoryDatabase = true;
  };
}
