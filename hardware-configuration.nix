{ config, lib, pkgs, ... }:

{
  # File systems (matching bootstrap)
  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
  };

  # Boot configuration (matching bootstrap exactly)
  boot = {
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
      generic-extlinux-compatible.configurationLimit = 3;
    };
    kernelModules = [ "bcm2835-v4l2" ];
    kernelPackages = pkgs.linuxPackages_rpi4;
    growPartition = true;
    initrd.includeDefaultModules = false;
    initrd.availableKernelModules = [
      "mmc_block" "usbhid" "usb_storage" "uas"
      "ext4" "crc32c"
    ];
  };

  # Hardware settings (matching bootstrap)
  hardware = {
    enableRedistributableFirmware = true;
    deviceTree = {
      enable = true;
      filter = "*rpi-4-*.dtb";
    };
  };

  # Platform
  nixpkgs.hostPlatform = "aarch64-linux";
}
