{ name, config, nodes, pkgs, modulesPath, ... }:

let
  readHostData = import ../lib/read-host-data.nix;
  iputils = import ../lib/iputils.nix;
  secrets = import ../lib/global-secrets.nix;

  wg_port = 51820;
  networks = (import ../lib/network-info.nix).networks;

  inherit (readHostData) allHosts;
  host = readHostData.info name;

  # Get device /dev/disk/by-uuid paths from host info
  bootDevice = host.filesystem."/dev/sda1";
  rootCryptDevice = host.luks."/dev/sda2";
  rootDevice = host.filesystem."/dev/mapper/cryptroot";
  dataCryptDevice = host.luks."/dev/sdb";
  dataDevice = host.filesystem."/dev/mapper/data";

  # Network interface names
  publicInterface = host.interfaces.public;
  privateInterface = host.interfaces.internal;

  privateNetGateway = networks.internal.gateway;
  privateNetwork = networks.internal.address;
  privateNetworkPrefix = networks.internal.prefixLength;

  privateIp = host.ipv4.internal.address;
  wireguardIp = host.ipv4.wireguard.address;

  wgFilterNotSelf = host: (host.fqdn != name);
  hostToWgPeer = otherHost: ({
    publicKey = (readHostData.secrets otherHost.fqdn).wireguard.public;
    allowedIPs = [ "${otherHost.ipv4.wireguard.address}/32" ];
    endpoint = "${otherHost.ipv4.internal.address}:${toString wg_port}";
  });
  wireguardPeers = map hostToWgPeer (builtins.filter wgFilterNotSelf allHosts);

  initrdAuthorizedKeys = builtins.concatLists (builtins.attrValues secrets.ssh.users);
  adminUsers =
    let
      mkUser = userName: keys: {
        isNormalUser = true;
        home = "/home/${userName}";
        extraGroups = [ "wheel" ];
        openssh.authorizedKeys.keys = keys;
      };
    in
    builtins.mapAttrs (userName: keys: mkUser userName keys)
      secrets.ssh.users;
in
{
  imports =
    [ (modulesPath + "/profiles/qemu-guest.nix")
    ];

  boot.initrd.availableKernelModules = [ "ahci" "virtio_pci" "sd_mod" "sr_mod" "virtio_net" "virtio" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" =
    { device = rootDevice;
      fsType = "ext4";
    };

  boot.initrd.luks.devices."cryptroot".device = rootCryptDevice;

  fileSystems."/boot" =
    { device = bootDevice;
      fsType = "vfat";
    };

  fileSystems."/data" =
    { device = dataDevice;
      fsType = "ext4";
    };

  boot.initrd.luks.devices."data".device = dataCryptDevice;

  swapDevices = [
    { device = "/var/swapfile";
      size = 2000;
    }
  ];

  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.systemd-boot.enable = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.devices = [ "/dev/sda" ];
  boot.loader.grub.enableCryptodisk = true;

  # Work around https://github.com/NixOS/nixpkgs/issues/91486
  boot.initrd.extraUtilsCommandsTest = pkgs.lib.mkForce "";
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      hostKeys = [
        /etc/secrets/initrd/ssh_host_rsa_key
        /etc/secrets/initrd/ssh_host_ed25519_key
      ];
      authorizedKeys = initrdAuthorizedKeys;
    };
  };

  networking.hostName = iputils.nameToHostname name;
  networking.domain = iputils.nameToDomain name;
  networking.privateIPv4 = wireguardIp;
  networking.publicIPv4 = host.ipv4.public.address;

  networking.extraHosts = with pkgs.lib; concatStringsSep "\n"
    (mapAttrsToList (n: v: "${v} ${n}")
      (filterAttrs (n: v: n != name)
        (mapAttrs (n: v: v.config.networking.privateIPv4) nodes)));

  networking.useDHCP = false;
  networking.interfaces."${publicInterface}" = {
    useDHCP = true;
    ipv6 = {
      addresses = [{ inherit (host.ipv6) address prefixLength; }];
      routes = [{ via = "fe80::1"; prefixLength = 0; address = "::"; }];
    };
  };
  networking.interfaces."${privateInterface}" = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "${privateIp}";
        prefixLength = 32;
      }
    ];
    ipv4.routes = [
      {
        address = privateNetGateway;
        prefixLength = 32;
      }
      {
        address = privateNetwork;
        prefixLength = privateNetworkPrefix;
        via = privateNetGateway;
      }
    ];
  };

  networking.firewall = {
    allowedTCPPorts = pkgs.lib.mkForce [];
    allowedUDPPorts = pkgs.lib.mkForce [];
    interfaces = {
      "${publicInterface}" = {
        allowedTCPPorts = [ 22 ];
        allowedUDPPorts = [];
      };
      "${privateInterface}" = {
        allowedTCPPorts = [];
        allowedUDPPorts = [ wg_port ];
      };
    };
  };
  networking.wireguard = {
    enable = true;
    interfaces = {
      wg0 = {
        ips = with host.ipv4.wireguard; [ "${address}/${toString prefixLength}" ];
        listenPort = wg_port;
        privateKeyFile = "/run/keys/wg-private";
        peers = wireguardPeers;
      };
    };
  };

  systemd.services.wireguard-wg0.after = [ "wg-private-key.service" ];
  systemd.services.wireguard-wg0.wants = [ "wg-private-key.service" ];

  i18n.defaultLocale = "en_GB.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "uk";
  };

  time.timeZone = "Etc/UTC";

  services = {
    openssh = {
      enable = true;
      permitRootLogin = "no";
      passwordAuthentication = false;
      challengeResponseAuthentication = false;
    };
    fail2ban =
      { enable = false;
        ignoreIP = with networks.wireguard; [ "${address}/${toString prefixLength}" ];
        jails =
          { sshd = ''
              enabled = true
            '';
          };
      };
    sshguard =
      { enable = true;
        whitelist = with networks.wireguard; [ "${address}/${toString prefixLength}" ];
        attack_threshold = 30;
        blocktime = 600;
        detection_time = 3600;
      };
  };

  environment.systemPackages = with pkgs; [
    htop
  ];

  nix.trustedUsers = [ secrets.ssh.nixopsAdmin ];
  security.sudo.wheelNeedsPassword = false;
  users.users = adminUsers;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "20.09"; # Did you read the comment?
}
