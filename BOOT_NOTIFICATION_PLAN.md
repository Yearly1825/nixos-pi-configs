# Boot Notification Implementation Plan

## Overview
Add NTFY boot notifications to sensors that send detailed system information (including all network interface IPs) on every boot, using NTFY configuration delivered securely from the discovery service.

## Architecture Decision
**Approach:** Discovery service delivers NTFY config as part of the encrypted bootstrap payload, sensors store it locally and use it for boot notifications.

**Why this approach:**
- Centralized NTFY configuration management
- No credentials in Git repositories
- NTFY config delivered encrypted during bootstrap
- Sensors autonomous after initial setup

---

## Phase 1: Discovery Service Changes

### 1.1 Update Core Configuration Model
**File:** `nix-sensor/discovery-service/app/core.py`

**Change:** Add NTFY config to encrypted payload in `SecurityManager.encrypt_payload()`

**Location:** Find the `encrypt_payload()` method (around line 200)

**Current code:**
```python
def encrypt_payload(self, data: Dict[str, Any], device_serial: str) -> str:
    """Encrypt payload for specific device using AES-256-GCM"""
    key = self.derive_device_key(device_serial)
    
    # Generate random nonce
    nonce = secrets.token_bytes(12)
    
    # Encrypt data
    plaintext = json.dumps(data).encode()
    # ... rest of encryption
```

**Change needed:** In the calling code where `config_payload` is created (in `app/main.py` around line 115), add NTFY configuration:

**File:** `nix-sensor/discovery-service/app/main.py`

**Find this section:**
```python
# Create encrypted configuration payload
config_payload = {
    "netbird_setup_key": config.netbird.setup_key,
    "ssh_keys": config.ssh_keys,
    "timestamp": int(time.time())
}
```

**Change to:**
```python
# Create encrypted configuration payload
config_payload = {
    "netbird_setup_key": config.netbird.setup_key,
    "ssh_keys": config.ssh_keys,
    "timestamp": int(time.time()),
    "ntfy_config": {
        "url": config.ntfy.url,
        "auth_type": config.ntfy.auth_type,
        "username": config.ntfy.username if config.ntfy.auth_type == "basic" else "",
        "password": config.ntfy.password if config.ntfy.auth_type == "basic" else "",
        "token": config.ntfy.token if hasattr(config.ntfy, 'token') and config.ntfy.auth_type == "bearer" else "",
        "priority": config.ntfy.priority,
        "tags": config.ntfy.tags
    } if config.ntfy.enabled else None
}
```

**Testing checkpoint:**
- Rebuild discovery service
- Check that NTFY config appears in encrypted payload
- Verify bootstrap still works with new payload structure

---

## Phase 2: Sensor Discovery Config Module Update

### 2.1 Update Discovery Config Application Script
**File:** `nixos-pi-configs/modules/discovery-config.nix`

**Change:** Add NTFY config extraction and storage

**Location:** In the `applyDiscoveryConfig` script, after the Netbird setup key section (around line 80)

**Add this code block:**
```bash
# Save NTFY configuration for boot notifications
echo "Extracting NTFY configuration..."
NTFY_CONFIG=$(${pkgs.jq}/bin/jq -c '.ntfy_config' "$CONFIG_FILE" 2>/dev/null || echo "null")

if [ -n "$NTFY_CONFIG" ] && [ "$NTFY_CONFIG" != "null" ]; then
  mkdir -p /var/lib/sensor-ntfy
  echo "$NTFY_CONFIG" > /var/lib/sensor-ntfy/config.json
  chmod 600 /var/lib/sensor-ntfy/config.json
  echo "NTFY configuration saved to /var/lib/sensor-ntfy/config.json"
else
  echo "No NTFY configuration found in discovery config"
fi
```

**Testing checkpoint:**
- Bootstrap a sensor
- Verify `/var/lib/sensor-ntfy/config.json` exists
- Check file permissions (should be 600)
- Verify JSON structure is correct

---

## Phase 3: Boot Notification Module Creation

### 3.1 Create Boot Notification Module
**File:** `nixos-pi-configs/modules/boot-notify.nix` (NEW FILE)

**Content:**
```nix
# Boot Notification Module
# Sends NTFY notification on every boot with system information and all network IPs

{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-notify;
  
  # Script to send boot notification
  bootNotifyScript = pkgs.writeScriptBin "boot-notify" ''
    #!${pkgs.bash}/bin/bash
    set -euo pipefail

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
```

**Testing checkpoint:**
- Build sensor configuration with new module
- Boot sensor
- Check journalctl for boot-notify service
- Verify NTFY notification received
- Confirm all IP addresses shown

---

## Phase 4: Integration into Sensor Configuration

### 4.1 Import Boot Notification Module
**File:** `nixos-pi-configs/configuration.nix`

**Location:** In the `imports` section (around line 19)

**Change from:**
```nix
imports = [
  ./hardware-configuration.nix
  ./modules/discovery-config.nix
  ./modules/kismet.nix
];
```

**Change to:**
```nix
imports = [
  ./hardware-configuration.nix
  ./modules/discovery-config.nix
  ./modules/kismet.nix
  ./modules/boot-notify.nix
];
```

### 4.2 Enable Boot Notifications
**File:** `nixos-pi-configs/configuration.nix`

**Location:** After the `services.discovery-config.enable = true;` line (around line 92)

**Add:**
```nix
# Enable boot notifications via NTFY
services.boot-notify.enable = true;
```

**Testing checkpoint:**
- Rebuild sensor configuration
- Deploy to test Pi
- Verify service is enabled
- Check systemd unit is created

---

## Phase 5: Testing & Validation

### 5.1 End-to-End Bootstrap Test
**Steps:**
1. Configure NTFY settings in `.deployment.yaml` (discovery service)
2. Start discovery service with updated code
3. Build fresh bootstrap image
4. Flash to SD card and boot new sensor
5. Monitor discovery service logs for registration
6. Wait for bootstrap completion
7. Wait for Pi to boot into final configuration
8. Check NTFY for boot notification

**Expected results:**
- Discovery service includes NTFY config in payload ✅
- Bootstrap saves NTFY config to `/var/lib/sensor-ntfy/config.json` ✅
- Boot notification service runs after network is ready ✅
- NTFY notification received with all interface IPs ✅

### 5.2 Reboot Test
**Steps:**
1. Reboot an already-provisioned sensor
2. Check NTFY for new boot notification
3. Verify all current IPs are shown
4. Verify VPN status is reported

**Expected results:**
- Notification sent on every boot ✅
- All network interfaces listed ✅
- Timestamps accurate ✅

### 5.3 Failure Mode Testing
**Test scenarios:**
1. **No NTFY config:** Sensor boots without NTFY config file
   - Expected: Service exits gracefully, no error
   
2. **Invalid NTFY URL:** NTFY URL unreachable
   - Expected: Curl retries 3 times, logs warning, boot continues
   
3. **Wrong credentials:** Invalid NTFY auth
   - Expected: HTTP error logged, boot continues
   
4. **No network:** Network unavailable during boot
   - Expected: Service times out after 30s, boot continues

**All failure modes should be non-fatal and not block boot process.**

---

## Phase 6: Documentation Updates

### 6.1 Update README.md
**File:** `nixos-pi-configs/README.md`

**Add section after "Services":**

```markdown
### Boot Notifications (`boot-notify.nix`)
- Sends NTFY notification on every boot
- Reports hostname, uptime, and all network interface IPs
- VPN connection status included
- Configuration delivered from discovery service
- Non-fatal failures (won't block boot)
```

### 6.2 Update Discovery Service README
**File:** `nix-sensor/discovery-service/README.md`

**Update "What It Does" section to mention NTFY config delivery:**

```markdown
When a Pi contacts the service:

1. **Authentication** - Pi proves it's yours using a secret key
2. **Name Assignment** - Gets next available name (`SENSOR-01`, `SENSOR-02`, etc.)  
3. **Secure Delivery** - Receives encrypted VPN keys, SSH keys, and NTFY config
4. **Confirmation** - Pi reports back when setup is complete
```

### 6.3 Update Main README
**File:** `nix-sensor/README.md`

**Update "What You Get" section:**

```markdown
📡 **Flexible Configuration**
- Deploy any NixOS configuration automatically
- Centralized configuration management via Git
- Secure distribution of credentials and keys
- Real-time bootstrap status monitoring
- Boot notifications with network information
```

---

## Phase 7: Deployment & Rollout

### 7.1 Discovery Service Deployment
**Steps:**
1. Commit discovery service changes
2. Rebuild discovery service: `cd nix-sensor/discovery-service && docker-compose build`
3. Restart service: `docker-compose restart`
4. Verify health: `curl http://localhost:8080/health`
5. Test registration with mock device (optional)

### 7.2 Sensor Configuration Deployment
**Steps:**
1. Commit sensor configuration changes to `nixos-pi-configs` repository
2. Tag release: `git tag v1.1.0-boot-notify`
3. Push changes: `git push origin main --tags`
4. Deploy to test sensor: `nixos-rebuild switch --flake github:yearly1825/nixos-pi-configs#sensor`
5. Monitor journalctl: `journalctl -u boot-notify -f`

### 7.3 Gradual Rollout
**Recommended approach:**
1. Deploy to 1-2 test sensors first
2. Monitor for 24 hours
3. Verify notifications on every boot
4. If successful, deploy to remaining sensors
5. Update bootstrap image for new deployments

---

## Success Criteria Checklist

- [ ] Discovery service delivers NTFY config in encrypted payload
- [ ] Sensor saves NTFY config during bootstrap
- [ ] Boot notification sent on every sensor boot
- [ ] All network interface IPs included in notification
- [ ] VPN status reported accurately
- [ ] Failed notifications don't block boot process
- [ ] Service times out gracefully (30s max)
- [ ] Works with all NTFY auth types (none, basic, bearer)
- [ ] No NTFY credentials stored in Git
- [ ] Documentation updated
- [ ] Tested on fresh bootstrap and existing sensors

---

## Rollback Plan

If issues arise:

1. **Discovery Service Rollback:**
   ```bash
   cd nix-sensor/discovery-service
   git revert HEAD
   docker-compose build
   docker-compose restart
   ```

2. **Sensor Configuration Rollback:**
   ```bash
   # On each sensor
   nixos-rebuild switch --flake github:yearly1825/nixos-pi-configs#sensor --revision <previous-commit>
   ```

3. **Disable Boot Notifications:**
   ```nix
   # Quick fix in configuration.nix
   services.boot-notify.enable = false;
   ```

---

## Security Considerations

### NTFY Config Storage
- **Location:** `/var/lib/sensor-ntfy/config.json`
- **Permissions:** `0600` (root only)
- **Encryption in transit:** Yes (encrypted payload from discovery service)
- **Encryption at rest:** No (but file is root-only)

### Credential Exposure
- **In Git:** ❌ No credentials in any repository
- **In Logs:** ⚠️ URLs may appear in journalctl (but not passwords)
- **In Transit:** ✅ Encrypted during bootstrap
- **At Rest:** ⚠️ JSON file readable by root

### Network Security
- **HTTPS recommended:** Use HTTPS NTFY URLs
- **Authentication:** Support all NTFY auth types
- **Timeout:** 30s max to prevent hanging

---

## Performance Impact

- **Boot time impact:** +5-10 seconds (waiting for network + sending notification)
- **Network usage:** ~1KB per boot (notification payload)
- **CPU impact:** Negligible
- **Disk usage:** ~1KB (NTFY config file)

---

## Future Enhancements (Out of Scope)

1. **Periodic heartbeat notifications** (daily/weekly status)
2. **Service status notifications** (Kismet, GPS, Netbird failures)
3. **Disk space alerts** (low storage warnings)
4. **Temperature monitoring** (CPU thermal alerts)
5. **Custom notification triggers** (user-defined events)

These can be added as separate modules later.

---

## Notes

- This implementation runs the notification service **on every boot**
- The service is ordered after `netbird-wt0.service` to ensure VPN IPs are captured
- Failures are logged but non-fatal (won't prevent system from booting)
- NTFY config is delivered once during bootstrap and reused on every subsequent boot
- To update NTFY settings, sensors must re-bootstrap or manually update `/var/lib/sensor-ntfy/config.json`

---

## Implementation Timeline

**Estimated total time:** 3-4 hours

- Phase 1 (Discovery Service): 30 minutes
- Phase 2 (Discovery Config Module): 30 minutes  
- Phase 3 (Boot Notify Module): 1-1.5 hours
- Phase 4 (Integration): 15 minutes
- Phase 5 (Testing): 45 minutes
- Phase 6 (Documentation): 30 minutes
- Phase 7 (Deployment): 30 minutes

---

## Ready for Implementation

This plan is ready to be handed to Claude Code for implementation. Each phase is clearly defined with:
- Exact file locations
- Code to find and modify
- Expected outcomes
- Testing checkpoints

Follow phases sequentially for best results.
