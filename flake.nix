{
  description = "Sensor configuration for Raspberry Pi";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    raspberry-pi-nix.url = "github:tstat/raspberry-pi-nix";
  };

  outputs = { self, nixpkgs, raspberry-pi-nix }: {
    nixosConfigurations.sensor = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        raspberry-pi-nix.nixosModules.raspberry-pi  # Changed this line
        {
          system.stateVersion = "24.05";

          # Hardcode the hostname you want
          networking.hostName = "sensor-test-01";

          # Basic Pi configuration
          hardware.raspberry-pi."4".apply-overlays-dtmerge.enable = true;

          # Your existing config
          services.openssh.enable = true;
          users.users.root.initialPassword = "bootstrap";

          # Add your packages
          environment.systemPackages = with nixpkgs.legacyPackages.aarch64-linux; [
            git curl jq vim htop
          ];
        }
      ];
    };
  };
}
