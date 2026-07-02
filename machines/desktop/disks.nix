{ lib, ... }:
let
  diskDevice = "/dev/nvme0n1";
in
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = diskDevice;
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      rootFsOptions = {
        compression = "zstd";
        atime = "off";
        xattr = "sa";
        acltype = "posixacl";
        "com.sun:auto-snapshot" = "false";
        mountpoint = "none";
      };
      options.ashift = "12";

      datasets = {
        root = {
          type = "zfs_fs";
          mountpoint = "/";
          options.mountpoint = "legacy";
        };
        nix = {
          type = "zfs_fs";
          mountpoint = "/nix";
          options.mountpoint = "legacy";
        };
        home = {
          type = "zfs_fs";
          mountpoint = "/home";
          options.mountpoint = "legacy";
        };
        docker = {
          type = "zfs_fs";
          mountpoint = "/var/lib/docker";
          options = {
            mountpoint = "legacy";
            recordsize = "128K";
          };
        };
        models = {
          type = "zfs_fs";
          mountpoint = "/models";
          options = {
            mountpoint = "legacy";
            compression = "off";
            recordsize = "1M";
          };
        };
      };
    };
  };
}
