{
  description = "Sensor configuration for Raspberry Pi";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";  # Match working Pi's 25.11
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.sensor = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        ./configuration.nix
        ./hardware-configuration.nix
        # Modules are imported directly in configuration.nix
        # This ensures they have access to the full system configuration
      ];
    };
  };
}
