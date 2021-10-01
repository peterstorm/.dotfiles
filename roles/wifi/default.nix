{ ...}:
{

  networking.wireless.enable = true;

  networking.networkmanager.unmanaged = [
    "*" "except:type:wwan" "except:type:gsm"
  ];
}
