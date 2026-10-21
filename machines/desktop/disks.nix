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

        # Native filesystem L2 KV offload tier introduced in r31 and restart-qualified
        # again by Infernal Invocation r18 (NATIVE_L2_PATH / NATIVE_L2_GB). FP8 KV blocks
        # are incompressible and written and read in large chunks. The quota is the point — NATIVE_L2_GB is a promise the runtime
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

        # DeepSeek-V4.1-Flash-1017 served by Project Maya (EXL3 3.5 bpw + the
        # Engram tables, its checkout and pack). Maya keeps the experts that do
        # not fit in VRAM in pinned RAM / the page cache and reads the rest from
        # the SSD on demand. ARC would cache the same bytes a second time out of
        # a 96 GB machine, so the dataset keeps only metadata in ARC.
        "models/ds41" = {
          type = "zfs_fs";
          mountpoint = "/models/ds41";
          options = {
            mountpoint = "legacy";
            compression = "off";
            recordsize = "1M";
            primarycache = "metadata";
          };
        };

        # DeepSeek's two Engram tables (203 GB), symlinked into the model folder.
        # The engine reads ~1 KB rows at random, 48 a token: under the parent's
        # 1M records with no data caching every row cost a 1 MB read (480 GB of
        # NVMe for a 6K-token prompt). Small records and a normal ARC instead.
        # Write these files with plain read/write (curl, dd): `cp` block-clones
        # on OpenZFS 2.4 and keeps the source's 1M blocks.
        "models/ds41/engram" = {
          type = "zfs_fs";
          mountpoint = "/models/ds41/engram";
          options = {
            mountpoint = "legacy";
            compression = "off";
            recordsize = "16K";
            primarycache = "all";
          };
        };
      };
    };
  };
}
