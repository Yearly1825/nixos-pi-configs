# Kismet Native Module Migration Plan

## Overview
Migrate from custom `services.kismet-sensor` module to NixOS native `services.kismet` module while maintaining current functionality for 4-interface USB Wi-Fi monitoring with GPS integration.

---

## Goals

### Primary Objectives
1. Replace custom Kismet module with NixOS native module
2. Maintain current monitoring configuration (4 USB Wi-Fi interfaces + GPS)
3. Improve security by running as unprivileged user with capabilities
4. Preserve hourly log rotation via restart timer
5. Keep firewall management within the module

### Success Criteria
- ✅ Kismet runs as unprivileged user with CAP_NET_RAW + CAP_NET_ADMIN
- ✅ All 4 USB interfaces monitored: `wlp1s0u1u{1-4}`
- ✅ GPS integration via GPSD (localhost:2947) works
- ✅ Web UI accessible on port 2501
- ✅ Logs written to `/var/lib/kismet/logs/` with timestamp rotation
- ✅ Hourly restart timer creates new log files
- ✅ Same or better security posture than current setup

---

## Phase 1: Research & Analysis ✅ COMPLETED

### 1.1 Native Module Capabilities (VERIFIED)
- **Location**: `nixpkgs/nixos/modules/services/networking/kismet.nix`
- **Key Features**:
  - Supports `settings` (structured) and `extraConfig` (literal)
  - Runs as unprivileged user by default with capabilities
  - Config file at `${dataDir}/.kismet/kismet_site.conf`
  - Pre-start script handles config symlinks
  - HTTP server configuration via `httpd.*` options
  - Firewall management via `openFirewall` option

### 1.2 Configuration Mapping

**Current Custom Module:**
```nix
services.kismet-sensor = {
  enable = true;
  extraConfig = ''
    source=wlp1s0u1u1
    source=wlp1s0u1u2
    source=wlp1s0u1u3
    source=wlp1s0u1u4
    gps=gpsd:host=localhost,port=2947
    httpd_bind_address=0.0.0.0
    httpd_port=2501
  '';
};
```

**Native Module (Proposed):**
```nix
services.kismet = {
  enable = true;
  
  # Web UI configuration
  httpd = {
    enable = true;
    address = "0.0.0.0";
    port = 2501;
  };
  
  # Log configuration
  logTypes = [ "kismet" "pcapng" "pcapppi" ];
  
  # Structured settings
  settings = {
    # USB Wi-Fi interfaces
    source.wlp1s0u1u1 = {};
    source.wlp1s0u1u2 = {};
    source.wlp1s0u1u3 = {};
    source.wlp1s0u1u4 = {};
    
    # GPS integration
    gps.gpsd = {
      host = "localhost";
      port = 2947;
    };
    
    # Log file naming with timestamps
    log_template = "%p/%n-%D-%t-%i.%l";
  };
};
```

### 1.3 Identified Differences

| Aspect | Custom Module | Native Module |
|--------|--------------|---------------|
| **User** | root | kismet (unprivileged) |
| **Capabilities** | Full root access | CAP_NET_RAW + CAP_NET_ADMIN |
| **Config Dir** | /root/.kismet | /var/lib/kismet/.kismet |
| **Data Dir** | /var/lib/kismet | /var/lib/kismet (same) |
| **Config Method** | extraConfig (literal) | settings (structured) |
| **Package Install** | In module | Move to configuration.nix |
| **Firewall** | Manual port opening | httpd.openFirewall option |
| **Security** | Minimal hardening | Full systemd hardening |

---

## Phase 2: Pre-Migration Preparation

### 2.1 Create Feature Branch
```bash
git checkout -b feature/kismet-native-module
git push -u origin feature/kismet-native-module
```

### 2.2 Backup Current State
- Tag current main: `git tag backup/pre-kismet-native`
- Document current service behavior:
  - Check running interfaces: `ip link show`
  - Check Kismet process: `ps aux | grep kismet`
  - Check logs location: `ls -la /var/lib/kismet/logs/`
  - Verify web UI access: `curl -I http://localhost:2501`

### 2.3 Test Environment Setup
**Option A: Test on existing Pi**
- Pros: Real hardware, realistic testing
- Cons: Could disrupt running sensor

**Option B: Fresh Pi deployment**
- Pros: Clean slate, no conflicts
- Cons: Requires additional hardware

**Recommendation**: Test on fresh Pi if available, otherwise test on existing Pi with rollback plan ready.

---

## Phase 3: Implementation

### 3.1 Update configuration.nix

**Changes Required:**

1. **Remove custom module import**
```nix
# REMOVE:
./modules/kismet.nix

# imports = [
#   ./hardware-configuration.nix
#   ./modules/discovery-config.nix
#   ./modules/kismet.nix  # ← REMOVE THIS LINE
#   ./modules/boot-notify.nix
# ];
```

2. **Add monitoring packages to systemPackages**
```nix
environment.systemPackages = with pkgs; [
  # Existing packages...
  git curl jq wget vim htop tmux
  
  # Network monitoring tools (moved from kismet.nix)
  kismet
  aircrack-ng
  hcxdumptool
  hcxtools
  tcpdump
  wireshark-cli
  nmap
  iftop
  netcat-gnu
  
  # GPS tools (already present)
  gpsd
  (python3.withPackages (ps: with ps; [ gps3 ]))
  
  # Additional tools (already present)
  iotop
  nethogs
  
  # RTL-SDR (moved from kismet.nix)
  rtl-sdr
  rtl_433
  
  # Python packages for Kismet (moved from kismet.nix)
  (python3.withPackages (ps: with ps; [
    gps3
    setuptools
    protobuf
    numpy
  ]))
];
```

3. **Replace custom Kismet service with native module**
```nix
# Replace services.kismet-sensor with:
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
    # Log configuration
    log_prefix = "/var/lib/kismet/logs/";
    log_title = "Kismet";
    log_template = "%p/%n-%D-%t-%i.%l";
    
    # USB Wi-Fi interfaces
    source.wlp1s0u1u1 = {};
    source.wlp1s0u1u2 = {};
    source.wlp1s0u1u3 = {};
    source.wlp1s0u1u4 = {};
    
    # GPS integration
    gps.gpsd = {
      host = "localhost";
      port = 2947;
    };
  };
};

# Keep firewall port open (native module handles this via httpd.openFirewall)
# The native module will add 2501 to allowedTCPPorts automatically
# So we can REMOVE the manual firewall rule:
# networking.firewall.allowedTCPPorts = [ 2501 ]; # ← Will be handled by module
```

4. **Preserve hourly restart timer**
```nix
# Add after services.kismet configuration
# Timer to restart Kismet every hour for log rotation
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
```

5. **Keep wireless regulatory domain settings**
```nix
# Already present in configuration.nix boot.kernelParams
# No changes needed - this is already set globally
```

### 3.2 Delete Custom Module
```bash
# After successful migration and testing:
git rm modules/kismet.nix
git commit -m "Remove custom Kismet module in favor of native module"
```

---

## Phase 4: Testing & Validation

### 4.1 Build Test
```bash
# Build configuration without deploying
nixos-rebuild build --flake .#sensor

# Check for build errors
echo $?  # Should be 0
```

### 4.2 Deployment Test (Staged)

**Step 1: Deploy to test Pi**
```bash
nixos-rebuild switch --flake .#sensor
```

**Step 2: Verify service status**
```bash
systemctl status kismet.service
journalctl -u kismet.service -f
```

**Step 3: Check running process**
```bash
ps aux | grep kismet
# Verify User is "kismet" not "root"
```

**Step 4: Verify capabilities**
```bash
getpcaps $(pgrep kismet)
# Should show: cap_net_admin,cap_net_raw=eip
```

**Step 5: Check interfaces**
```bash
# From Kismet CLI (if available) or web UI
curl http://localhost:2501/datasources/all_sources.json
# Or check logs for interface initialization
journalctl -u kismet.service | grep "source"
```

**Step 6: Verify GPS integration**
```bash
journalctl -u kismet.service | grep -i gps
# Should show GPSD connection messages
```

**Step 7: Test web UI**
```bash
curl -I http://localhost:2501
# Should return 200 OK or 401 (auth required)
```

**Step 8: Verify log rotation**
```bash
ls -lh /var/lib/kismet/logs/
# Wait 1 hour, check for new log file after restart
```

**Step 9: Check timer**
```bash
systemctl list-timers | grep kismet
# Should show kismet-restart.timer active
```

### 4.3 Functional Tests

**Test 1: Packet Capture**
- Verify Kismet is capturing packets from all 4 interfaces
- Check packet count in web UI or logs
- Confirm different APs/clients detected

**Test 2: GPS Correlation**
- Verify GPS coordinates appear in logs
- Check if detected devices have GPS tags
- Confirm GPSD connection is stable

**Test 3: Web UI Access**
- Access http://<pi-ip>:2501
- Set initial admin password
- Navigate dashboards
- Check if all 4 interfaces shown

**Test 4: Log File Creation**
- Confirm logs written to `/var/lib/kismet/logs/`
- Verify filename has timestamp format
- Check file permissions (should be kismet:kismet)

**Test 5: Hourly Restart**
- Wait for 1 hour after boot
- Confirm Kismet restarts
- Verify new log file created
- Check for any errors in journal

### 4.4 Security Validation

**Check 1: User/Group**
```bash
id kismet
# Should exist as system user
```

**Check 2: Capabilities**
```bash
# Verify Kismet has ONLY required capabilities
getpcaps $(pgrep kismet)
# Expected: cap_net_admin,cap_net_raw=eip
```

**Check 3: Systemd Hardening**
```bash
systemctl show kismet.service | grep -E "Protect|Private|Restrict"
# Should show multiple hardening options enabled
```

**Check 4: Config File Permissions**
```bash
ls -la /var/lib/kismet/.kismet/
# kismet_site.conf should be readable by kismet user
```

---

## Phase 5: Documentation Updates

### 5.1 Update README.md

**Section: Services**

Replace:
```markdown
### Kismet Network Monitor (`kismet.nix`)
- Web UI on port 2501 (username: `kismet`, password: `kismet`)
- Logs to `/var/lib/kismet/logs/`
- Config directory: `/root/.kismet/`
- Auto-restart every hour for log rotation
- Default sources: `wlp1s0u1u1`, `wlp1s0u1u2`, `wlp1s0u1u3`, `wlp1s0u1u4`
```

With:
```markdown
### Kismet Network Monitor (Native NixOS Module)
- Web UI on port 2501 (set password on first login)
- Runs as unprivileged user `kismet` with network capabilities
- Logs to `/var/lib/kismet/logs/` with timestamp-based rotation
- Config directory: `/var/lib/kismet/.kismet/`
- Auto-restart every hour for log file rotation
- Monitors 4 USB Wi-Fi interfaces: `wlp1s0u1u{1-4}`
- GPS integration via GPSD (localhost:2947)
- Security: CAP_NET_RAW + CAP_NET_ADMIN capabilities, systemd hardening
```

### 5.2 Update configuration.nix Comments

Add comment block above `services.kismet`:
```nix
# Kismet wireless network monitoring
# Uses native NixOS module with unprivileged user + capabilities
# Web UI: http://<ip>:2501 (set password on first login)
# Logs: /var/lib/kismet/logs/ (rotated hourly via restart timer)
services.kismet = {
  # ...
};
```

### 5.3 Create Migration Notes

Add section to `KISMET_NATIVE_MIGRATION_PLAN.md`:
```markdown
## Post-Migration Notes for Deployed Sensors

### First-Time Setup After Migration
1. Access web UI: `http://<sensor-ip>:2501`
2. Create admin user and password
3. Verify all 4 interfaces are active
4. Check GPS lock in dashboard

### Troubleshooting
- Service logs: `journalctl -u kismet.service -f`
- Check user: `ps aux | grep kismet` (should show user `kismet`)
- Check capabilities: `getpcaps $(pgrep kismet)`
- Verify interfaces: `ip link show | grep wlp1s0u1u`
```

---

## Phase 6: Deployment & Rollout

### 6.1 Pre-Deployment Checklist
- [ ] All tests passed in Phase 4
- [ ] Documentation updated in Phase 5
- [ ] Feature branch builds successfully
- [ ] Rollback plan ready (see Phase 7)
- [ ] Test Pi running stable for 24+ hours

### 6.2 Merge to Main
```bash
git checkout main
git merge feature/kismet-native-module
git tag v2.0.0-kismet-native
git push origin main --tags
```

### 6.3 Deployment Strategy

**Option A: Fresh Bootstrap** (Recommended for new sensors)
- Build new bootstrap image with updated config
- Flash to SD card
- Deploy normally via discovery service
- No migration needed

**Option B: In-Place Update** (For existing sensors)
```bash
# On the sensor Pi:
cd /etc/nixos-sensor
git pull origin main
nixos-rebuild switch --flake .#sensor

# Verify service
systemctl status kismet.service
```

### 6.4 Gradual Rollout Plan
1. Deploy to 1 test sensor
2. Monitor for 48 hours
3. If stable, deploy to 2-3 more sensors
4. Monitor for 1 week
5. Deploy to remaining sensors

---

## Phase 7: Rollback Plan

### 7.1 Quick Rollback (If deployment fails)
```bash
# On sensor Pi:
git checkout backup/pre-kismet-native
nixos-rebuild switch --flake .#sensor

# Or use previous generation:
nixos-rebuild switch --rollback
```

### 7.2 Git Rollback (If merged to main)
```bash
git revert <merge-commit-hash>
git push origin main
```

### 7.3 Emergency Manual Fix
If Kismet fails to start:
```bash
# Check logs
journalctl -u kismet.service -n 50

# Temporary disable
systemctl stop kismet.service
systemctl disable kismet.service

# Fix configuration
vim /etc/nixos/configuration.nix

# Rebuild
nixos-rebuild switch
```

---

## Phase 8: Cleanup

### 8.1 Remove Obsolete Files
```bash
# Delete custom module (after successful deployment)
git rm modules/kismet.nix
git commit -m "Remove obsolete custom Kismet module"
```

### 8.2 Archive Old Implementation
```bash
# Keep tagged for reference
git tag archive/custom-kismet-module backup/pre-kismet-native
git push origin --tags
```

### 8.3 Update Issue Tracking
- Close migration issue (if exists)
- Document lessons learned
- Update TODO.md (remove Kismet migration items)

---

## Known Issues & Mitigations

### Issue 1: Interface Names May Change
**Symptom**: USB Wi-Fi dongles get different names after reboot  
**Mitigation**: Interface names are stable per user confirmation, but if this changes, consider udev rules to fix names  
**Workaround**: Update `settings.source.<name>` in configuration.nix

### Issue 2: GPSD Not Ready on Boot
**Symptom**: Kismet starts before GPSD, fails to connect to GPS  
**Mitigation**: Native module already waits for network-online.target  
**Additional Fix**: Ensure `systemd.services.kismet.after = [ "gpsd.service" ];` (already in module)

### Issue 3: Web UI Password Reset
**Symptom**: Admin forgets password, can't access UI  
**Mitigation**: Password stored in `/var/lib/kismet/.kismet/kismet_httpd.conf`  
**Fix**: `sudo rm /var/lib/kismet/.kismet/kismet_httpd.conf && systemctl restart kismet.service`

### Issue 4: Log Directory Permissions
**Symptom**: Kismet can't write logs, service fails  
**Mitigation**: Native module creates directories with correct permissions via tmpfiles.rules  
**Fix**: `sudo chown -R kismet:kismet /var/lib/kismet`

### Issue 5: Hourly Restart Interrupts Active Capture
**Symptom**: Data loss during restart  
**Mitigation**: Kismet flushes logs before shutdown, restart takes <5 seconds  
**Alternative**: Consider removing timer and using external log rotation instead

---

## Performance Expectations

### Before Migration (Custom Module)
- **User**: root
- **Memory**: ~150-200MB per Kismet instance
- **CPU**: 10-30% on Pi 4 (varies with traffic)
- **Boot Time**: ~60-90 seconds to Kismet start

### After Migration (Native Module)
- **User**: kismet (unprivileged)
- **Memory**: Same (~150-200MB)
- **CPU**: Same (10-30%)
- **Boot Time**: Similar (~60-90 seconds)
- **Security**: Improved (capabilities + hardening)

### Expected Changes
- ✅ No performance degradation expected
- ✅ Slightly better security (systemd hardening)
- ✅ Easier configuration management (structured settings)
- ⚠️ One-time manual password setup required

---

## Success Metrics

### Technical Metrics
- [ ] Kismet service starts successfully
- [ ] All 4 USB Wi-Fi interfaces active
- [ ] GPS coordinates in captured data
- [ ] Web UI accessible on port 2501
- [ ] Logs written to `/var/lib/kismet/logs/`
- [ ] Hourly restart creates new log files
- [ ] No systemd errors in journal
- [ ] Process runs as user `kismet` (not root)
- [ ] Capabilities limited to CAP_NET_RAW + CAP_NET_ADMIN

### Operational Metrics
- [ ] Sensor uptime > 7 days without issues
- [ ] No increase in memory usage
- [ ] No increase in CPU usage
- [ ] Same or better packet capture rate
- [ ] GPS lock maintained across restarts

---

## Timeline Estimate

- **Phase 1** (Research): ✅ Complete
- **Phase 2** (Preparation): 30 minutes
- **Phase 3** (Implementation): 1-2 hours
- **Phase 4** (Testing): 2-3 hours (including 1-hour wait for restart timer)
- **Phase 5** (Documentation): 30 minutes
- **Phase 6** (Deployment): 1-2 hours (depending on rollout strategy)
- **Phase 7** (Rollback - if needed): 30 minutes
- **Phase 8** (Cleanup): 15 minutes

**Total Estimated Time**: 6-9 hours (including wait times for testing)

---

## References

- **NixOS Kismet Module**: `nixpkgs/nixos/modules/services/networking/kismet.nix`
- **Kismet Documentation**: https://www.kismetwireless.net/docs/
- **Analysis Document**: `NIXOS_KISMET_ANALYSIS.md`
- **Override Analysis**: `NIXOS_KISMET_OVERRIDE_ANALYSIS.md`
- **Linux Capabilities**: https://man7.org/linux/man-pages/man7/capabilities.7.html

---

## Notes

- This migration maintains feature parity with the custom module
- Security is improved via unprivileged user + capabilities
- Configuration is more maintainable (structured settings vs literal strings)
- Aligns with NixOS best practices
- Future upstream improvements will benefit from native module usage

---

## Ready for Implementation

This plan is ready for execution. Proceed with Phase 2 (Feature Branch Creation) when ready.
