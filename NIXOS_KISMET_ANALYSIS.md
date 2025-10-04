# NixOS Kismet Module: Complete Configuration Workflow Analysis

## Overview
This document provides a comprehensive analysis of how the NixOS Kismet module works, based on the actual source code from `nixpkgs/nixos/modules/services/networking/kismet.nix`.

## 1. Module Source Location
- **Module Path**: `nixos/modules/services/networking/kismet.nix` in the nixpkgs repository
- **Test Path**: `nixos/tests/kismet.nix`
- **Maintainer**: @numinit

## 2. Configuration Options

The NixOS Kismet module provides the following configuration options:

### Basic Options

```nix
services.kismet = {
  enable = true;                    # Boolean, default: false
  package = pkgs.kismet;            # Package to use, default: pkgs.kismet
  user = "kismet";                  # User to run as, default: "kismet"
  group = "kismet";                 # Group to run as, default: "kismet"
  serverName = "Kismet";            # Server name, default: "Kismet"
  serverDescription = "NixOS Kismet server";  # Description
  logTypes = [ "kismet" ];          # List of log types, default: ["kismet"]
  dataDir = "/var/lib/kismet";      # Data directory, default: "/var/lib/kismet"
};
```

### HTTP Server Options

```nix
services.kismet.httpd = {
  enable = false;                   # Enable HTTP server, default: false
  address = "127.0.0.1";            # Listen address (must be IP, not hostname!)
  port = 2501;                      # Listen port, default: 2501
};
```

### Advanced Configuration Options

The module provides two ways to configure Kismet:

1. **`settings`**: A structured Nix attribute set (RECOMMENDED)
2. **`extraConfig`**: Literal config lines (for special cases)

## 3. Configuration File Generation

### Where the Config File is Placed

The Kismet configuration is generated and placed at:
```
${cfg.dataDir}/.kismet/kismet_site.conf
```

With default settings, this resolves to:
```
/var/lib/kismet/.kismet/kismet_site.conf
```

### How Config Generation Works

The module uses a sophisticated conversion function `mkKismetConf` that:
1. Converts Nix attribute sets to Kismet's configuration format
2. Supports complex nested configurations
3. Handles various data types (atoms, lists, key-value pairs)
4. Supports special syntax (e.g., `foo'` becomes `foo+` for `+=` syntax)

The generated config is written using:
```nix
kismetConf = pkgs.writeText "kismet.conf" ''
  ${mkKismetConf settings}
  ${cfg.extraConfig}
'';
```

Then symlinked during service startup:
```bash
ln -sf ${kismetConf} kismet_site.conf
```

## 4. User Workflow: From Nix Configuration to Runtime

### Step 1: User Declares Configuration in NixOS

Users edit their NixOS configuration (e.g., `/etc/nixos/configuration.nix`):

```nix
{ config, pkgs, ... }:

{
  services.kismet = {
    enable = true;
    serverName = "My Wireless Monitor";
    httpd.enable = true;
    
    settings = {
      # Add a wireless source - this is the equivalent of source=wlan0
      source.wlan0 = {
        name = "My Wifi Card";
      };
      
      # Add GPS configuration
      gps.gpsd = {
        host = "localhost";
        port = 2947;
      };
    };
  };
}
```

### Step 2: NixOS Rebuild

User runs:
```bash
sudo nixos-rebuild switch
```

### Step 3: Module Processes Configuration

1. The module merges user settings with defaults:
   ```nix
   settings = cfg.settings // {
     server_name = cfg.serverName;
     server_description = cfg.serverDescription;
     logging_enabled = cfg.logTypes != [];
     log_types = cfg.logTypes;
   } // optionalAttrs cfg.httpd.enable {
     httpd_bind_address = cfg.httpd.address;
     httpd_port = cfg.httpd.port;
     httpd_auth_file = "${configDir}/kismet_httpd.conf";
     httpd_home = "${cfg.package}/share/kismet/httpd";
   };
   ```

2. Converts settings to Kismet config format using `mkKismetConf`

3. Creates a Nix store derivation with the generated config

### Step 4: Service Starts

The systemd service (`kismet.service`) is created with:

```nix
ExecStartPre = "+${kismetPreStart}";  # Runs as root to set up directories
ExecStart = "${cfg.package}/bin/kismet --homedir ${cfg.dataDir} --confdir ${configDir} --no-ncurses -f ${configDir}/kismet.conf";
```

The pre-start script:
1. Creates `~/.kismet` directory (which is `/var/lib/kismet/.kismet`)
2. Symlinks default config files from the package
3. Symlinks the generated `kismet_site.conf`
4. Sets proper permissions

### Step 5: Runtime

Kismet runs and reads:
- Default configs from `/nix/store/.../etc/*.conf` (symlinked)
- Site config from `/var/lib/kismet/.kismet/kismet_site.conf` (symlinked to Nix store)
- User auth file from `/var/lib/kismet/.kismet/kismet_httpd.conf` (mutable)

## 5. The `settings` Option: Detailed Usage

The `settings` option is a powerful, type-safe way to configure Kismet. It supports various configuration patterns:

### Pattern 1: Simple Atoms (Strings, Numbers, Booleans)

```nix
settings = {
  dot11_link_bssts = false;           # Boolean
  dot11_related_bss_window = 10000000; # Integer
  devicefound = "00:11:22:33:44:55";  # String
};
```

Generates:
```
dot11_link_bssts=false
dot11_related_bss_window=10000000
devicefound=00:11:22:33:44:55
```

### Pattern 2: Using `+=` Syntax with `'` Suffix

```nix
settings = {
  log_types' = "wiglecsv";  # Note the ' suffix
};
```

Generates:
```
log_types+=wiglecsv
```

### Pattern 3: Lists of Atoms

```nix
settings = {
  wepkey = [ "00:DE:AD:C0:DE:00" "FEEDFACE42" ];
};
```

Generates:
```
wepkey=00:DE:AD:C0:DE:00,FEEDFACE42
```

### Pattern 4: Lists of Lists (Multiple Lines)

```nix
settings = {
  alert = [
    [ "ADHOCCONFLICT"  "5/min" "1/sec" ]
    [ "ADVCRYPTCHANGE" "5/min" "1/sec" ]
  ];
};
```

Generates:
```
alert=ADHOCCONFLICT,5/min,1/sec
alert=ADVCRYPTCHANGE,5/min,1/sec
```

### Pattern 5: Key-Value Pairs

```nix
settings = {
  source.wlan0 = {
    name = "My WiFi Card";
  };
};
```

Generates:
```
source=wlan0:name=My WiFi Card
```

### Pattern 6: Nested Structures with Headers

```nix
settings = {
  gps.gpsd = {
    host = "localhost";
    port = 2947;
  };
};
```

Generates:
```
gps=gpsd:host=localhost,port=2947
```

### Pattern 7: Complex Nested Lists

```nix
settings = {
  apspoof.Foo1 = [
    {
      ssid = "Bar1";
      validmacs = [ "00:11:22:33:44:55" "aa:bb:cc:dd:ee:ff" ];
    }
    {
      ssid = "Bar2";
      validmacs = [ "01:12:23:34:45:56" "ab:bc:cd:de:ef:f0" ];
    }
  ];
};
```

Generates:
```
apspoof=Foo1:ssid=Bar1,validmacs="00:11:22:33:44:55,aa:bb:cc:dd:ee:ff"
apspoof=Foo1:ssid=Bar2,validmacs="01:12:23:34:45:56,ab:bc:cd:de:ef:f0"
```

## 6. The `extraConfig` Option

For configurations that don't fit the `settings` pattern, use `extraConfig`:

```nix
services.kismet.extraConfig = ''
  # Custom config lines that don't fit the settings schema
  source=wlan0:name=My Card,hop=false
  
  # Complex configurations
  wepkey=00:DE:AD:C0:DE:00,FEEDFACE42
'';
```

**Note**: The module documentation recommends using `settings` over `extraConfig` whenever possible, as `settings` provides type safety and validation.

## 7. Common Use Case: Adding a WiFi Source

Traditional Kismet config file editing:
```bash
# Edit /etc/kismet/kismet_site.conf
source=wlan0
```

NixOS approach:
```nix
services.kismet = {
  enable = true;
  settings = {
    source.wlan0 = {
      name = "Primary Monitor";
    };
  };
};
```

Or with just the interface:
```nix
services.kismet = {
  enable = true;
  settings = {
    source.wlan0 = {};  # Minimal config
  };
};
```

Or using extraConfig:
```nix
services.kismet = {
  enable = true;
  extraConfig = ''
    source=wlan0
  '';
};
```

## 8. Key Differences from Traditional Kismet Configuration

| Aspect | Traditional Kismet | NixOS Module |
|--------|-------------------|--------------|
| **Config File Location** | `/etc/kismet/kismet_site.conf` (manually edited) | `/var/lib/kismet/.kismet/kismet_site.conf` (generated) |
| **Editing Method** | Direct file editing | Declarative Nix configuration |
| **Persistence** | File persists, manual backups | Config in Nix files, version controlled |
| **Validation** | Runtime errors only | Compile-time type checking (with `settings`) |
| **Reproducibility** | Manual process | Fully reproducible from Nix config |
| **Secrets Management** | In config files | Can use NixOS secrets management |
| **Updates** | Manual merge required | Declarative, no manual merging |

## 9. Directory Structure at Runtime

```
/var/lib/kismet/               # cfg.dataDir (home directory)
├── .kismet/                   # ${cfg.dataDir}/.kismet (configDir)
│   ├── kismet.conf            # Symlink to /nix/store/.../etc/kismet.conf
│   ├── kismet_site.conf       # Symlink to generated Nix store config
│   ├── kismet_httpd.conf      # Mutable file (user passwords, created at runtime)
│   ├── kismet_manuf.txt.gz    # Symlink to package
│   └── ...other config files  # Symlinked from package
└── ...log files and data      # Generated during runtime
```

## 10. Complete Working Example

Here's a complete, real-world NixOS configuration for Kismet:

```nix
{ config, pkgs, ... }:

{
  services.kismet = {
    enable = true;
    
    # Server identification
    serverName = "HomeNetwork-Monitor";
    serverDescription = "Home wireless network monitoring";
    
    # Enable web interface
    httpd = {
      enable = true;
      address = "0.0.0.0";  # Listen on all interfaces
      port = 2501;
    };
    
    # Logging configuration
    logTypes = [ "kismet" "pcapng" "wiglecsv" ];
    
    # Detailed settings
    settings = {
      # Monitor wlan0 interface
      source.wlan0 = {
        name = "Primary WiFi Card";
      };
      
      # GPS configuration (if using GPSD)
      gps.gpsd = {
        host = "localhost";
        port = 2947;
      };
      
      # Add wiglecsv to log types (using += syntax)
      log_types' = "wiglecsv";
      
      # Alert configuration
      alert = [
        [ "ADHOCCONFLICT"  "5/min" "1/sec" ]
        [ "ADVCRYPTCHANGE" "5/min" "1/sec" ]
      ];
    };
  };
  
  # Open firewall for web interface
  networking.firewall.allowedTCPPorts = [ 2501 ];
  
  # Add user to kismet group for admin access
  users.users.youruser.extraGroups = [ "kismet" ];
}
```

After `nixos-rebuild switch`, access the web interface at `http://localhost:2501`.

## 11. Setting HTTP Password

Unlike traditional Kismet, the password must be set manually in a mutable file:

```bash
sudo -u kismet bash
echo "httpd_username=admin" >> /var/lib/kismet/.kismet/kismet_httpd.conf
echo "httpd_password=your_password" >> /var/lib/kismet/.kismet/kismet_httpd.conf
exit
sudo systemctl restart kismet.service
```

This is by design - passwords are mutable and should not be in the Nix store.

## 12. Type System and Validation

The module defines a sophisticated type system:

```nix
atom = oneOf [ number bool str ];
listOfAtom = listOf' atom;
atomOrList = either atom listOfAtom;
lists = listOf' atomOrList;
kvPair = attrsOf' atomOrList;
kvPairs = listOf' kvPair;
headerKvPair = attrsOf' (attrsOf' atomOrList);
headerKvPairs = attrsOf' (listOf' (attrsOf' atomOrList));
topLevel = oneOf [ headerKvPairs headerKvPair kvPairs kvPair listOfAtom lists atom ];
```

This ensures compile-time validation of your Kismet configuration.

## 13. Systemd Service Details

The service runs with security hardening:

```nix
serviceConfig = {
  Type = "simple";
  User = "kismet";
  Group = "kismet";
  
  # Required capabilities for packet capture
  CapabilityBoundingSet = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
  AmbientCapabilities = [ "CAP_NET_ADMIN" "CAP_NET_RAW" ];
  
  # Security hardening
  LockPersonality = true;
  NoNewPrivileges = true;
  PrivateTmp = true;
  ProtectClock = true;
  ProtectControlGroups = true;
  ProtectHome = true;
  ProtectHostname = true;
  ProtectKernelLogs = true;
  ProtectKernelModules = true;
  ProtectKernelTunables = true;
  ProtectProc = "invisible";
  ProtectSystem = "full";
  RestrictNamespaces = true;
  RestrictSUIDSGID = true;
  UMask = "0007";
};
```

## 14. References

- **Module Source**: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/services/networking/kismet.nix
- **Test File**: https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/kismet.nix
- **Kismet Docs**: https://www.kismetwireless.net/docs/readme/configuring/configfiles/
- **NixOS Manual**: https://nixos.org/manual/nixos/stable/

## 15. Summary

The NixOS Kismet module provides a fully declarative, type-safe way to configure Kismet. Unlike traditional approaches:

1. Configuration is declared in Nix, not edited in config files
2. The config file is generated and placed in `/var/lib/kismet/.kismet/kismet_site.conf`
3. Users specify configuration through `settings` (structured) or `extraConfig` (literal)
4. The `settings` option supports complex nested configurations with compile-time validation
5. Adding a WiFi source like `source=wlan0` becomes `settings.source.wlan0 = {}`
6. The entire configuration is reproducible and version-controllable
7. The service runs with appropriate security hardening and Linux capabilities

This approach aligns with the NixOS philosophy of declarative, reproducible system configuration.
