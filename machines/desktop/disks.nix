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
        # Model weights. Pre-compressed safetensors, read sequentially in ~1 MiB
        # chunks at load, never rewritten — so large records and no compression.
        models = {
          type = "zfs_fs";
          mountpoint = "/models";
          options = {
            mountpoint = "legacy";
            compression = "off";
            recordsize = "1M";
          };
        };

        # vLLM JIT cache: compiled kernels, CUDA graphs, /container-tmp. Many
        # small-to-medium text and object files that compress well, which is the
        # opposite of what the parent dataset is tuned for — a cold cache costs
        # ~20 minutes of compilation at startup, so it is worth keeping and worth
        # storing properly.
        "models/vllm-cache" = {
          type = "zfs_fs";
          mountpoint = "/models/vllm-cache";
          options = {
            mountpoint = "legacy";
            compression = "zstd";
            recordsize = "128K";
          };
        };

        # Native filesystem L2 KV offload tier introduced in r31 and retained
        # by r33 (NATIVE_L2_PATH / NATIVE_L2_GB). FP8 KV blocks:
        # incompressible, written and read in large
        # chunks. The quota is the point — NATIVE_L2_GB is a promise the runtime
        # makes about a directory, with nothing stopping it from filling the pool
        # underneath the 155 GiB checkpoint and /nix. Keep the two in step:
        # raising NATIVE_L2_GB past 512 means raising this quota first.
        "models/native-l2" = {
          type = "zfs_fs";
          mountpoint = "/models/native-l2";
          options = {
            mountpoint = "legacy";
            compression = "off";
            recordsize = "1M";
            quota = "512G";
          };
        };
      };
    };
  };
}
