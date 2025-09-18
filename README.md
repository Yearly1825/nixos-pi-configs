# NixOS Pi Sensor Configuration

This repository contains the NixOS configuration for Raspberry Pi sensors that are automatically provisioned through the discovery service.

## Overview

This configuration provides:
- **Automatic hostname assignment** from discovery service
- **SSH key deployment** for secure remote access
- **Netbird VPN** auto-connection for remote management
- **Kismet** network monitoring service
- **Firewall** configuration with appropriate rules

## How It Works

1. **Bootstrap Phase**: The Pi boots with a bootstrap image and registers with the discovery service
2. **Configuration Retrieval**: The Pi receives:
   - Unique hostname (e.g., `SENSOR-01`, `SENSOR-02`)
   - SSH public keys for access
   - Netbird setup key for VPN enrollment
3. **Configuration Application**: This repository's configuration is applied via `nixos-rebuild boot`
4. **Services Startup**: After reboot, the Pi:
   - Sets its hostname from the discovery configuration
   - Applies SSH keys for secure access
   - Connects to Netbird VPN automatically
   - Starts Kismet monitoring service

## Modules

### `discovery-config.nix`
Reads configuration from `/var/lib/nixos-bootstrap/discovery_config.json` and applies:
- Hostname setting
- SSH key deployment to root and nixos users
- Netbird setup key storage

### `netbird.nix`
Manages Netbird VPN connection:
- One-time enrollment using setup key
- Automatic connection on boot
- Reconnection on network changes

### `kismet.nix`
Configures Kismet network monitoring:
- Web UI on port 2501
- Customizable monitoring interfaces
- GPS support (optional)
- Logging and alerting

## Configuration

### Basic Configuration

The default configuration in `configuration.nix` provides a working setup with:
- SSH access (key-only authentication)
- Netbird VPN connection
- Kismet with web UI
- Open firewall ports (22, 2501)

### Customization

1. **Copy the example site configuration**:
   ```bash
   cp site-config.nix.example site-config.nix
   ```

2. **Edit `site-config.nix`** to customize:
   - Kismet monitoring interfaces
   - Web UI credentials
   - GPS settings
   - Additional packages
   - Network optimizations

3. **Import your site configuration** in `configuration.nix`:
   ```nix
   imports = [
     ./hardware-configuration.nix
     ./modules/discovery-config.nix
     ./modules/netbird.nix
     ./modules/kismet.nix
     ./site-config.nix  # Add this line
   ];
   ```

## Kismet Configuration

### Monitoring Interfaces

Configure which interfaces to monitor in `site-config.nix`:

```nix
services.kismet-sensor.interfaces = [
  # 2.4GHz monitoring
  "wlan0:type=linuxwifi,hop=true,hop_channels=\"1,6,11\""
  
  # 5GHz monitoring (if you have a second adapter)
  "wlan1:type=linuxwifi,hop=true,hop_channels=\"36,40,44,48\""
];
```

### Web UI Access

Default credentials:
- URL: `http://<pi-ip>:2501`
- Username: `kismet`
- Password: `changeme`

**Important**: Change these in production!

### GPS Support

If you have a GPS module connected:

```nix
services.kismet-sensor.gps = {
  enable = true;
  host = "127.0.0.1";
  port = 2947;
};
```

## Accessing Your Sensors

### Via Netbird VPN

Once enrolled, sensors are accessible via their Netbird IP:
```bash
# Check Netbird status
netbird status

# SSH to sensor
ssh root@<netbird-ip>
```

### Via Local Network

If on the same network:
```bash
# SSH access
ssh root@<sensor-hostname>.local

# Kismet Web UI
http://<sensor-hostname>.local:2501
```

## Monitoring and Maintenance

### Check Service Status

```bash
# Netbird VPN status
systemctl status netbird
netbird status

# Kismet status
systemctl status kismet
journalctl -u kismet -f

# Discovery config application
systemctl status apply-discovery-config
```

### View Logs

```bash
# Kismet logs
ls -la /var/lib/kismet/logs/

# System logs
journalctl -xe
```

### Manual Service Control

```bash
# Restart Kismet
systemctl restart kismet

# Reconnect Netbird
netbird down
netbird up

# Rebuild configuration
nixos-rebuild switch
```

## Troubleshooting

### Netbird Won't Connect

1. Check setup key is present:
   ```bash
   cat /var/lib/netbird/setup-key
   ```

2. Check enrollment status:
   ```bash
   ls -la /var/lib/netbird/.enrolled
   ```

3. Try manual enrollment:
   ```bash
   netbird up --setup-key <key> --management-url https://nb.a28.dev
   ```

### Kismet Issues

1. Check if interface exists:
   ```bash
   ip link show
   iw dev
   ```

2. Manually set monitor mode:
   ```bash
   iw wlan0 set type monitor
   ip link set wlan0 up
   ```

3. Check Kismet logs:
   ```bash
   journalctl -u kismet -n 100
   ```

### SSH Access Problems

1. Verify SSH keys were applied:
   ```bash
   cat /root/.ssh/authorized_keys
   ```

2. Check discovery config:
   ```bash
   cat /var/lib/nixos-bootstrap/discovery_config.json
   ```

## Security Considerations

1. **Change default passwords**: Modify Kismet web UI credentials in production
2. **SSH security**: Only key-based authentication is enabled
3. **Firewall**: Only necessary ports are open (22, 2501)
4. **VPN-only access**: Consider restricting SSH/Kismet to VPN interface only
5. **Regular updates**: Keep the configuration updated with `nixos-rebuild`

## Advanced Configuration

### Restrict Services to VPN Only

To make SSH and Kismet accessible only via VPN:

```nix
# In site-config.nix
services.openssh.listenAddresses = [
  { addr = "100.64.0.1"; port = 22; }  # Netbird IP only
];

services.kismet-sensor.httpd.bindAddress = "100.64.0.1";  # Netbird IP only
```

### Custom Monitoring Scripts

Add custom monitoring tools:

```nix
environment.systemPackages = [
  (pkgs.writeScriptBin "sensor-status" ''
    #!/usr/bin/env bash
    echo "=== Sensor Status ==="
    echo "Hostname: $(hostname)"
    echo "Uptime: $(uptime)"
    echo "=== Network ==="
    ip addr show dev wt0 | grep inet
    echo "=== Services ==="
    systemctl is-active netbird kismet
  '')
];
```

### Performance Tuning

For better packet capture performance:

```nix
boot.kernel.sysctl = {
  "net.core.rmem_max" = 134217728;
  "net.core.wmem_max" = 134217728;
  "net.core.netdev_max_backlog" = 5000;
};
```

## Support

For issues or questions:
1. Check service logs with `journalctl`
2. Verify discovery configuration in `/var/lib/nixos-bootstrap/`
3. Ensure all required services are running
4. Check network connectivity and firewall rules