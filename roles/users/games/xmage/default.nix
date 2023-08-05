{ config, pkgs, lib, ...}:
  let xmage = pkgs.xmage.overrideAttrs (oa: rec {
    version = "1.4.51-dev_2023-08-04_02-48";
    src = builtins.fetchurl {
      url = "http://xmage.today/files/mage-full_${version}.zip";
      sha256 = "007j9vlji34prdyagprszssl08j8p89fsihhws3h937hq01ql862";
    };
  });
  in {
    home.packages = [ xmage ];
  }
