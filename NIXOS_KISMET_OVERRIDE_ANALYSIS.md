# NixOS Kismet Module Override Analysis

## Executive Summary

**Can the native NixOS Kismet module be configured to run as root with /root/.kismet config directory?**

**YES**, but with important caveats. The native module can be overridden using systemd service overrides, but some features (like the pre-start script) may not work as intended when running as root.

---

## 1. Default Configuration of Native Module

### Default User/Group
- **User**: `"kismet"` (default value in `services.kismet.user`)
- **Group**: `"kismet"` (default value in `services.kismet.group`)
- **Home Directory**: `/var/lib/kismet` (default value in `services.kismet.dataDir`)
- **Config Directory**: `/var/lib/kismet/.kismet` (derived as `${cfg.dataDir}/.kismet`)

### Systemd Service Configuration
```nix
systemd.services.kismet = {
  serviceConfig = {
    User = cfg.user;                    # "kismet" by default
    Group = cfg.group;                  # "kismet" by default
    WorkingDirectory = cfg.dataDir;     # /var/lib/kismet by default
    
    # Capabilities (works without root)
    CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
    
    # Security hardening
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = false;
    PrivateTmp = true;
    PrivateUsers = false;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;              # This will block /root access!
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProtectSystem = "full";
    RestrictNamespaces = true;
    RestrictSUIDSGID = true;
    UMask = "0007";
    TimeoutStopSec = 30;
  };
};
```

### ExecStart Command
```nix
ExecStart = escapeShellArgs [
  "${cfg.package}/bin/kismet"
  "--homedir"
  cfg.dataDir                           # /var/lib/kismet
  "--confdir"
  configDir                             # /var/lib/kismet/.kismet
  "--datadir"
  "${cfg.package}/share"
  "--no-ncurses"
  "-f"
  "${configDir}/kismet.conf"
];
```

### Pre-Start Script
The module includes a **privileged** pre-start script that runs as root (note the `+` prefix):

```nix
ExecStartPre = "+${kismetPreStart}";
```

This script:
1. Creates the `~/.kismet` directory
2. Symlinks config files from the package
3. Sets proper ownership using the configured user/group
4. Un-symlinks mutable files like `kismet_httpd.conf`

**Important**: The `~` in the script refers to the **user's home directory** as defined by the User in serviceConfig, which would be `/var/lib/kismet` (the kismet user's home).

---

## 2. Can You Override User/Group?

### YES - Using serviceConfig Override

You can override the User and Group using `systemd.services.kismet.serviceConfig`:

```nix
{
  services.kismet = {
    enable = true;
    # ... other config
  };
  
  # Override to run as root
  systemd.services.kismet.serviceConfig = {
    User = lib.mkForce "root";
    Group = lib.mkForce "root";
  };
}
```

**Result**: The service will run as root user/group.

---

## 3. Can You Override ExecStart?

### YES - But You Need to Replace the Entire Command

```nix
systemd.services.kismet.serviceConfig.ExecStart = lib.mkForce (
  escapeShellArgs [
    "${pkgs.kismet}/bin/kismet"
    "--homedir"
    "/root"
    "--confdir"
    "/root/.kismet"
    "--datadir"
    "${pkgs.kismet}/share"
    "--no-ncurses"
    "-f"
    "/root/.kismet/kismet.conf"
  ]
);
```

**Result**: Kismet will use `/root/.kismet` as the config directory.

---

## 4. Critical Issues with Running as Root

### Issue 1: ProtectHome = true
The native module sets `ProtectHome = true`, which **blocks access to `/root`**!

**Solution**: You must override this:
```nix
systemd.services.kismet.serviceConfig.ProtectHome = lib.mkForce false;
```

### Issue 2: Pre-Start Script Assumes Non-Root User
The pre-start script runs commands like:
```bash
owner=${escapeShellArg "${cfg.user}:${cfg.group}"}
chown "$owner" ~/ ~/.kismet
```

When you override User/Group to root, this becomes:
```bash
owner="root:root"
chown "root:root" ~/ ~/.kismet
```

The `~/` path will resolve to **root's home** (`/root`) because the script runs as root (note the `+` prefix on `ExecStartPre`), but the module's `dataDir` setting still points to `/var/lib/kismet` in the generated config files.

**This creates a mismatch**: The pre-start script will try to set up `/root/.kismet`, but the generated config will still reference `/var/lib/kismet`.

### Issue 3: Generated Config File Path
The module generates a config file using `cfg.dataDir`:
```nix
configDir = "${cfg.dataDir}/.kismet";
```

Even if you override the systemd User, the **generated config is still placed based on `services.kismet.dataDir`**, which defaults to `/var/lib/kismet`.

---

## 5. Complete Override Solution

To fully replicate your custom module's behavior (run as root, use /root/.kismet):

```nix
{ config, pkgs, lib, ... }:

{
  services.kismet = {
    enable = true;
    user = "root";                    # Change the module's user
    group = "root";                   # Change the module's group  
    dataDir = "/root";                # Change the data directory to /root
    
    # Your other config
    serverName = "My Kismet Server";
    httpd.enable = true;
    settings = {
      source.wlan0 = { name = "WiFi"; };
    };
  };
  
  # Override hardening options that block /root access
  systemd.services.kismet.serviceConfig = {
    ProtectHome = lib.mkForce false;  # Allow access to /root
  };
}
```

### Why This Works

1. **`user = "root"`** → Sets `cfg.user` to "root", so `User = cfg.user` becomes `User = "root"`
2. **`group = "root"`** → Sets `cfg.group` to "root", so `Group = cfg.group` becomes `Group = "root"`
3. **`dataDir = "/root"`** → Sets `cfg.dataDir` to "/root", so:
   - `--homedir` becomes `/root`
   - `configDir` becomes `/root/.kismet`
   - `--confdir` becomes `/root/.kismet`
   - Pre-start script operates on `/root/.kismet`
4. **`ProtectHome = false`** → Removes the systemd protection that blocks /root access

### User/Group Creation
The native module creates users/groups automatically:
```nix
users.groups.${cfg.group} = { };
users.users.${cfg.user} = {
  inherit (cfg) group;
  description = "User for running Kismet";
  isSystemUser = true;
  home = cfg.dataDir;
};
```

When you set `user = "root"` and `group = "root"`, these declarations become:
```nix
users.groups.root = { };        # No-op, root group already exists
users.users.root = {            # No-op, root user already exists
  group = "root";
  description = "User for running Kismet";
  isSystemUser = true;
  home = "/root";
};
```

NixOS will recognize that the root user/group already exists and skip creation.

---

## 6. Alternative: Minimal Override (Not Recommended)

If you want to override **only** the systemd service without changing the module config:

```nix
{
  services.kismet = {
    enable = true;
    # Use default settings
  };
  
  systemd.services.kismet.serviceConfig = {
    User = lib.mkForce "root";
    Group = lib.mkForce "root";
    WorkingDirectory = lib.mkForce "/root";
    ProtectHome = lib.mkForce false;
    
    ExecStart = lib.mkForce (
      lib.escapeShellArgs [
        "${pkgs.kismet}/bin/kismet"
        "--homedir"
        "/root"
        "--confdir"
        "/root/.kismet"
        "--datadir"
        "${pkgs.kismet}/share"
        "--no-ncurses"
        "-f"
        "/root/.kismet/kismet.conf"
      ]
    );
  };
}
```

**Problems with this approach**:
1. The pre-start script will still reference `/var/lib/kismet` in variable names
2. The generated config symlink will point to the wrong location
3. The module's `settings` won't be used correctly
4. You lose the benefits of the module's config generation

**Verdict**: Don't do this. Use the proper override method (setting `user`, `group`, and `dataDir` options).

---

## 7. Is There a DynamicUser?

**NO** - The native module does **NOT** use `DynamicUser = true`.

It creates a **static system user** named "kismet":
```nix
users.users.${cfg.user} = {
  inherit (cfg) group;
  description = "User for running Kismet";
  isSystemUser = true;
  home = cfg.dataDir;
};
```

This means:
- The user is created at system build time with a fixed UID
- No conflicts with DynamicUser restrictions
- You can override User to "root" without DynamicUser issues

---

## 8. Security Hardening vs Root Access

### Hardening Options That May Conflict

When running as root with `/root/.kismet`, you need to disable:

1. **`ProtectHome = true`** → MUST be set to `false` to access `/root`

These are fine to keep even when running as root:
- `CapabilityBoundingSet / AmbientCapabilities` → Root has all capabilities anyway
- `LockPersonality` → Safe to keep
- `NoNewPrivileges` → Safe to keep  
- `PrivateDevices = false` → Already false, needed for network devices
- `PrivateTmp` → Safe to keep
- `ProtectClock` → Safe to keep
- `ProtectControlGroups` → Safe to keep
- `ProtectHostname` → Safe to keep
- `ProtectKernelLogs` → Safe to keep
- `ProtectKernelModules` → Safe to keep
- `ProtectKernelTunables` → Safe to keep
- `ProtectProc` → Safe to keep
- `ProtectSystem = "full"` → Safe to keep (only protects /usr, /boot, /efi)
- `RestrictNamespaces` → Safe to keep
- `RestrictSUIDSGID` → Safe to keep

### Recommended Override
```nix
systemd.services.kismet.serviceConfig = {
  # Only override what's necessary
  ProtectHome = lib.mkForce false;
};
```

---

## 9. Comparison: Custom Module vs Native + Override

### Your Custom Module
```nix
{
  services.kismet-custom = {
    enable = true;
    config = ''
      source=wlan0
      # ... other config
    '';
  };
}
```

**Implementation**:
- User: `root` (hardcoded)
- Group: `root` (hardcoded)
- Home: `/root` (hardcoded)
- Config: `/root/.kismet/kismet_site.conf`
- ExecStart: `${pkgs.kismet}/bin/kismet --confdir /root/.kismet ...`

### Native Module with Override
```nix
{
  services.kismet = {
    enable = true;
    user = "root";
    group = "root";
    dataDir = "/root";
    
    settings = {
      source.wlan0 = { name = "WiFi"; };
    };
  };
  
  systemd.services.kismet.serviceConfig.ProtectHome = lib.mkForce false;
}
```

**Implementation**:
- User: `root` (via `user` option)
- Group: `root` (via `group` option)
- Home: `/root` (via `dataDir` option)
- Config: `/root/.kismet/kismet_site.conf` (generated)
- ExecStart: `${pkgs.kismet}/bin/kismet --confdir /root/.kismet ...`

### Functional Equivalence

| Feature | Custom Module | Native + Override |
|---------|---------------|-------------------|
| Runs as root | ✅ Yes | ✅ Yes |
| Uses /root/.kismet | ✅ Yes | ✅ Yes |
| Config generation | ❌ Manual string | ✅ Type-safe Nix attrs |
| Capabilities | ✅ CAP_NET_RAW/ADMIN | ✅ CAP_NET_RAW/ADMIN |
| Pre-start setup | ❌ None | ✅ Automatic symlinks |
| HTTP auth setup | ❌ Manual | ✅ Automated |
| Hardening | ❌ None | ✅ Full (with ProtectHome=false) |
| Config validation | ❌ Runtime only | ✅ Build-time checking |

---

## 10. Final Recommendations

### ✅ Use Native Module with Override

**Recommended Configuration**:
```nix
{ config, pkgs, lib, ... }:

{
  services.kismet = {
    enable = true;
    
    # Run as root with /root/.kismet
    user = "root";
    group = "root";
    dataDir = "/root";
    
    # Server config
    serverName = "My Kismet Server";
    serverDescription = "Wireless monitoring";
    
    # Enable web UI
    httpd = {
      enable = true;
      address = "0.0.0.0";
      port = 2501;
    };
    
    # Structured configuration
    settings = {
      source.wlan0 = {
        name = "Primary WiFi";
      };
      
      # Add more sources
      source.wlan1 = {
        name = "Secondary WiFi";
      };
      
      # GPS if needed
      gps.gpsd = {
        host = "localhost";
        port = 2947;
      };
    };
  };
  
  # Allow access to /root
  systemd.services.kismet.serviceConfig.ProtectHome = lib.mkForce false;
  
  # Open firewall if needed
  networking.firewall.allowedTCPPorts = [ 2501 ];
}
```

### Why This is Better Than Custom Module

1. **Type Safety**: Config validated at build time
2. **Structured Configuration**: Use Nix attrs instead of string interpolation
3. **Automatic Setup**: Pre-start script handles symlinks and permissions
4. **Security**: Retains all hardening except ProtectHome
5. **Maintainability**: Uses upstream module, gets updates automatically
6. **Flexibility**: Can still use `extraConfig` for edge cases
7. **Testing**: Module is tested in nixpkgs CI

### Migration Path

1. **Step 1**: Add native module config alongside custom module
2. **Step 2**: Verify both produce same runtime behavior
3. **Step 3**: Disable custom module
4. **Step 4**: Remove custom module code

---

## 11. Potential Blockers: NONE FOUND

### ❌ NOT Blocked by DynamicUser
The module does not use `DynamicUser = true`.

### ❌ NOT Blocked by User Override
You can override `User` via the module option or serviceConfig.

### ❌ NOT Blocked by ExecStart Override  
You can override `ExecStart`, but it's better to use module options.

### ❌ NOT Blocked by Hardening
Only `ProtectHome` needs to be disabled; all other hardening is compatible.

### ✅ Fully Compatible
The native module is **fully flexible** and can replicate custom module behavior.

---

## 12. Upstream Module Design Philosophy

The native module follows NixOS best practices:

1. **Principle of Least Privilege**: Runs as unprivileged user by default
2. **Security by Default**: Heavy systemd hardening
3. **Declarative Config**: Type-safe structured configuration
4. **Flexibility**: Allows overrides for advanced use cases
5. **Reproducibility**: Generated configs in Nix store

The module **expects** to run as non-root with capabilities, but **allows** running as root when explicitly configured.

---

## 13. Conclusion

### Can You Replicate Custom Module Behavior?

**YES - Completely**

```nix
{
  # Instead of this custom module:
  services.kismet-custom.enable = true;
  
  # Use this:
  services.kismet = {
    enable = true;
    user = "root";
    group = "root";
    dataDir = "/root";
    settings = { /* your config */ };
  };
  systemd.services.kismet.serviceConfig.ProtectHome = lib.mkForce false;
}
```

### Blockers?

**NONE** - All requirements can be met:
- ✅ Run as root: Set `user = "root"`
- ✅ Use /root/.kismet: Set `dataDir = "/root"`
- ✅ Custom flags: Module provides all necessary flags
- ✅ Override restrictions: No DynamicUser or other hard blocks
- ✅ Hardening conflicts: Only ProtectHome needs override

### Should You Migrate?

**YES** - The native module provides:
- Same runtime behavior as custom module
- Better configuration management
- Type safety and validation
- Automatic updates from nixpkgs
- Better security posture
- Community support

**There are no technical blockers to migration.**
