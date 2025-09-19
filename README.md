# NixOS Pi Sensor Configuration

NixOS configuration for Raspberry Pi sensors with automatic discovery service provisioning. Built with Nix flakes targeting NixOS 25.11.

## Services

### Discovery Config (`discovery-config.nix`)
- Reads configuration from `/var/lib/nixos-bootstrap/discovery_config.json`
- Applies SSH keys to root and nixos users
- Stores Netbird setup key for VPN enrollment
- Sets hostname from discovery service

### Netbird VPN (`netbird.nix`)
- Auto-enrollment using setup key from discovery config
- Connects to `https://nb.a28.dev` management server
- Creates `wt0` interface for VPN traffic
- Firewall allows UDP 51820 and trusts `wt0` interface

### Kismet Network Monitor (`kismet.nix`)
- Web UI on port 2501 (username: `kismet`, password: `kismet`)
- Logs to `/var/lib/kismet/logs/`
- Config directory: `/root/.kismet/`
- Auto-restart every hour for log rotation
- Default sources: `wlp1s0u1u1`, `wlp1s0u1u2`, `wlp1s0u1u3`, `wlp1s0u1u4`

## Building and Deployment

This configuration uses Nix flakes. To build:

```bash
# Build the configuration
nix build .#nixosConfigurations.sensor.config.system.build.toplevel

# Apply to a running system
nixos-rebuild switch --flake .#sensor
```

### GPS Daemon
- GPSD listens on devices: `/dev/ttyUSB0`, `/dev/ttyACM0`
- Port 2947 for GPS data
- Kismet configured to use `gpsd:host=localhost,port=2947`

## Installed Packages

**Network Monitoring:**
- kismet, aircrack-ng, hcxdumptool, hcxtools
- tcpdump, wireshark-cli, nmap, iftop, netcat-gnu

**GPS Tools:**
- gpsd, python3-gps3

**RTL-SDR:**
- rtl-sdr, rtl_433

**System Tools:**
- git, curl, jq, wget, vim, htop, tmux, iotop, nethogs

**Helper Scripts:**
- `netbird-fix`, `netbird-enroll`, `sensor-status`
- `gps-check`, `kismet-config`, `kismet-logs`

## Firewall

Open ports: 22 (SSH), 2501 (Kismet Web UI)

## Build

```bash
nixos-rebuild switch --flake .#sensor
```