# Migration TODO: Netbird Custom to NixOS Native Module

## Overview
Migrate from custom `netbird-sensor` module to NixOS native `services.netbird` while maintaining setup key-based auto-enrollment capability for sensor bootstrapping.

---

## Phase 1: Research & Planning ✅ COMPLETED

- [x] **1.1** Review NixOS Netbird module source code
  - Location: `nixpkgs/nixos/modules/services/networking/netbird.nix`
  - **Findings:**
    - Native module supports multiple clients via `services.netbird.clients.<name>`
    - Key options: `autoStart`, `config`, `environment`, `interface`, `port`, `logLevel`
    - Hardened mode available with dedicated user
    - Support for DNS resolver, firewall management
    - UI wrapper optional
    - Module updated in PR #246055 to support multiple tunnels

- [x] **1.2** Research setup key enrollment support
  - **Findings:**
    - ✅ Native module supports setup keys via `environment` option
    - Can pass `NB_SETUP_KEY` environment variable to service
    - NetBird CLI supports: `netbird up --setup-key <KEY>`
    - All CLI flags can be environment variables: `NB_<FLAGNAME>` format
    - Example: `NB_SETUP_KEY`, `NB_MANAGEMENT_URL`, `NB_ADMIN_URL`
    - **Conclusion:** Native module CAN support our auto-enrollment requirement

- [x] **1.3** Identify gaps between native module and our requirements
  - **Gaps identified:**
    1. ❌ No built-in enrollment marker (`/var/lib/netbird/.enrolled`)
    2. ❌ No automatic "enroll once" logic (native module doesn't prevent re-enrollment)
    3. ❌ Helper scripts need updating for native service names
    4. ⚠️ Need to verify state preservation across reboots
  - **Compatible features:**
    1. ✅ Custom management URL via `NB_MANAGEMENT_URL` environment variable
    2. ✅ Auto-start via `autoStart` option
    3. ✅ Interface name (`wt0`) via `interface` option
    4. ✅ Firewall via `openFirewall` option
    5. ✅ Logging to journald (no file logging issues)

- [x] **1.4** Design migration approach
  - **Decision: Hybrid Approach (Recommended)**
    - Use native `services.netbird.clients.<name>` for daemon
    - Pass setup key via `environment.NB_SETUP_KEY`
    - Keep lightweight enrollment wrapper to handle "enroll once" logic
    - Preserve helper scripts with minor updates
  
  - **Configuration Mapping:**
    ```nix
    # BEFORE (custom):
    services.netbird-sensor = {
      enable = true;
      managementUrl = "https://nb.a28.dev";
      autoConnect = true;
    };
    
    # AFTER (native + wrapper):
    services.netbird.clients.wt0 = {
      autoStart = true;
      port = 51820;
      interface = "wt0";
      openFirewall = true;
      logLevel = "info";
      environment = {
        NB_SETUP_KEY = ""; # Set by enrollment script
        NB_MANAGEMENT_URL = "https://nb.a28.dev";
        NB_ADMIN_URL = "https://nb.a28.dev";
      };
    };
    # + Custom oneshot service to populate NB_SETUP_KEY from discovery config
    ```
  
  - **Backward Compatibility:**
    - Enrollment marker can be preserved
    - State in `/var/lib/netbird/` should be compatible
    - May need migration script to update service name in systemd
  
  - **Key Implementation Details:**
    1. Use `services.netbird.clients.wt0` (named after interface)
    2. Create systemd drop-in or EnvironmentFile for setup key
    3. Read setup key from discovery config into `/var/lib/netbird/env`
    4. Native service reads environment file
    5. Keep enrollment marker to prevent re-running setup

---

## Phase 2: Test Environment Setup

- [ ] **2.1** Create test branch
  - Branch name: `feature/native-netbird-module`
  - Based on current `main`

- [ ] **2.2** Set up local test environment
  - Option A: QEMU aarch64 VM with NixOS
  - Option B: Spare Raspberry Pi for testing
  - Option C: NixOS container on dev machine

- [ ] **2.3** Create test discovery config
  - Mock `/var/lib/nixos-bootstrap/discovery_config.json`
  - Include test setup key and SSH keys
  - Document test credentials

---

## Phase 3: Implementation

### Phase 3A: Native Module Integration (Preferred Path)

- [ ] **3A.1** Replace custom service with native module
  - In `configuration.nix`, change:
    ```nix
    services.netbird-sensor = { ... };
    ```
    to:
    ```nix
    services.netbird = {
      enable = true;
      # ... map options
    };
    ```

- [ ] **3A.2** Configure native module options
  - Set management server URL
  - Configure tunnel interface name (`wt0`)
  - Set ports and firewall rules

- [ ] **3A.3** Create enrollment wrapper service
  - New service: `netbird-bootstrap-enroll.service`
  - Runs before native netbird service
  - Reads setup key from discovery config
  - Calls `netbird up --setup-key` if not enrolled

- [ ] **3A.4** Update discovery-config module
  - Keep setup key extraction logic
  - Adjust enrollment marker location if needed
  - Ensure compatibility with native module

- [ ] **3A.5** Preserve helper scripts
  - Keep `netbird-fix`, `netbird-enroll` scripts
  - Update to work with native module paths
  - Adjust for new service name (`netbird.service`)

### Phase 3B: Hybrid Approach (If Native Module Insufficient)

- [ ] **3B.1** Use native module for daemon only
  - Enable `services.netbird` for core service
  - Override `systemd.services.netbird` ExecStart if needed

- [ ] **3B.2** Keep custom enrollment logic
  - Retain `netbird-enroll` service
  - Adjust dependencies for native service

- [ ] **3B.3** Minimize service conflicts
  - Use `mkForce` or `mkOverride` where necessary
  - Document all overrides with comments

---

## Phase 4: Testing

- [ ] **4.1** Test fresh deployment
  - Deploy to test Pi with no prior Netbird config
  - Verify discovery config → enrollment → connection flow
  - Check VPN interface creation and routing

- [ ] **4.2** Test already-enrolled sensor
  - Deploy to Pi with existing `/var/lib/netbird/.enrolled`
  - Verify auto-connect without re-enrollment
  - Check that enrolled state is preserved

- [ ] **4.3** Test failure scenarios
  - Missing discovery config
  - Invalid setup key
  - Network unavailable during enrollment
  - Verify retry logic and error messages

- [ ] **4.4** Test helper scripts
  - Run `netbird-fix` and verify output
  - Run `netbird-enroll` manually
  - Run `sensor-status` and check Netbird section

- [ ] **4.5** Verify logs
  - Check `journalctl -u netbird`
  - Confirm no file logging errors
  - Verify logs readable and complete

- [ ] **4.6** Performance testing
  - Check boot time impact
  - Monitor memory usage vs. custom module
  - Verify VPN throughput unchanged

---

## Phase 5: Documentation

- [ ] **5.1** Update `README.md`
  - Document new Netbird configuration
  - Update service names if changed
  - Revise troubleshooting section

- [ ] **5.2** Update module comments
  - Remove or update `modules/netbird.nix` header
  - Document why native module is used
  - Note any overrides or customizations

- [ ] **5.3** Document migration for existing sensors
  - Write upgrade procedure (if needed)
  - Note any manual steps for deployed sensors
  - Create rollback plan

- [ ] **5.4** Update helper script docs
  - Update inline help text if service names changed
  - Verify examples in scripts still accurate

---

## Phase 6: Deployment

- [ ] **6.1** Merge to main branch
  - Code review (if team project)
  - Squash commits or keep history as appropriate
  - Tag release version (e.g., `v2.0.0-native-netbird`)

- [ ] **6.2** Deploy to staging sensors (if available)
  - Deploy to 1-2 sensors first
  - Monitor for 24-48 hours
  - Check logs and VPN connectivity

- [ ] **6.3** Gradual rollout to production sensors
  - Deploy in batches (e.g., 10% at a time)
  - Monitor each batch for issues
  - Pause if errors detected

- [ ] **6.4** Update deployment automation
  - Update any CI/CD pipelines
  - Update build scripts or documentation

---

## Phase 7: Cleanup

- [ ] **7.1** Remove obsolete code
  - Delete old `modules/netbird.nix` if fully replaced
  - Remove unused tmpfiles rules
  - Clean up redundant options

- [ ] **7.2** Archive custom implementation
  - Tag old version for reference
  - Document reason for migration in git commit
  - Keep branch available for rollback if needed

- [ ] **7.3** Monitor long-term
  - Check logs weekly for first month
  - Gather feedback from deployed sensors
  - Document any issues or improvements

---

## Success Criteria

- ✅ All sensors auto-enroll using setup key from discovery service
- ✅ VPN connection established and stable
- ✅ No file logging errors in systemd logs
- ✅ Helper scripts work correctly
- ✅ Boot time unchanged or improved
- ✅ Code reduced and maintainability improved
- ✅ Leveraging upstream NixOS module for future updates

---

## Rollback Plan

If migration fails or causes issues:

1. Revert to tagged previous version
2. Rebuild and redeploy: `nixos-rebuild switch --flake .#sensor`
3. Document failure reason in GitHub issues
4. Re-evaluate approach in Phase 1

---

## Notes

- **Current issue fixed**: Added `--log-file console` to disable file logging (commit: [hash])
- **Priority**: Medium (current implementation works but not idiomatic)
- **Estimated effort**: 8-16 hours over 2-3 weeks
- **Risk level**: Low (can rollback easily with Nix)
