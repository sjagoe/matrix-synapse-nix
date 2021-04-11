#! /usr/bin/env bash

set -eu
set -o pipefail


function installRequirements() {
    # Installing nix requires `sudo`; the Hetzner rescue mode doesn't have it.
    # We use jq to build an info.json file used to seed nix expressions.
    apt-get install -y sudo jq
}

function wipeDrive() {
    local device="$1"
    cryptsetup open --type plain -d /dev/urandom "$device" wipe
    time dd if=/dev/zero of=/dev/mapper/wipe bs=16K status=progress || true
    cryptsetup close wipe || true
    # For large drives, it can take a while for all writes to
    # flush... Give it a few tries to close.
    if [[ -f /dev/mapper/wipe ]]; then
        cryptsetup close wipe || true
    fi
    if [[ -f /dev/mapper/wipe ]]; then
        cryptsetup close wipe
    fi
}

function luksFormat() {
    local device="$1"
    local name="$2"
    local label="$3"
    set +x
    echo "Setting up LUKS on $device"
    echo -n "$LUKS_PASSPHRASE" | \
        cryptsetup -y -v -d - \
                   --cipher=aes-xts-plain64 --key-size=512 --hash=sha512 \
                   luksFormat "$device"
    echo -n "$LUKS_PASSPHRASE" | cryptsetup -d - open "$device" "$name"
    mkfs.ext4 -F -L "$label" "/dev/mapper/$name"
}

function recordDeviceUUID() {
    local device="$1"
    local type="$2"
    local uuid=

    uuid="$(blkid "$device" | sed -n 's/.* UUID=\"\([^\"]*\)\".*/\1/p')"

    if [[ ! -e "$INFO_JSON" ]]; then
        echo '{}' >> "$INFO_JSON"
    fi

    jq --arg device "$device" --arg type "$type" --arg path "/dev/disk/by-uuid/$uuid" \
       '.[$type][$device] = $path' < "$INFO_JSON" > "${INFO_JSON}.tmp"

    mv "${INFO_JSON}.tmp" "$INFO_JSON"
}

function recordInterface() {
    local name="$1"
    local type="$2"

    if [[ ! -e "$INFO_JSON" ]]; then
        echo '{}' >> "$INFO_JSON"
    fi

    jq --arg name "$name" --arg type "$type" \
       '.interfaces[$type] = $name' < "$INFO_JSON" > "${INFO_JSON}.tmp"

    mv "${INFO_JSON}.tmp" "$INFO_JSON"
}

function partition() {
    local device="$1"
    # We seem to only be able to boot from a mbr formatted drive?
    parted -s "$device" -- mklabel msdos \
           mkpart primary fat32 4 514 \
           mkpart primary ext4 514 -0
    partprobe "$device"
}

function installNix() {
    # Allow installing nix as root, see
    #   https://github.com/NixOS/nix/issues/936#issuecomment-475795730
    mkdir -p /etc/nix
    echo "build-users-group =" > /etc/nix/nix.conf

    echo "Installing nix"
    sh /root/install-nix.sh
    set +u +x # sourcing this may refer to unset variables that we have no control over
    # shellcheck disable=SC1090
    source "$HOME/.nix-profile/etc/profile.d/nix.sh"
    # shellcheck disable=SC2016
    echo -e '\nsource "$HOME/.nix-profile/etc/profile.d/nix.sh"\n' >> ~/.bashrc
    set -u -x
}

function addChannel() {
    # Keep in sync with `system.stateVersion` set below!
    nix-channel --add "https://nixos.org/channels/nixos-$SYSTEM_STATE_VERSION" nixpkgs
    nix-channel --update --verbose
}

function generateConfig() {
    # Getting NixOS installation tools
    nix-env -iE "_: with import <nixpkgs/nixos> { configuration = {}; }; with config.system.build; [ nixos-generate-config nixos-install nixos-enter manual.manpages ]"

    nixos-generate-config --root /mnt
}

function getPublicInterface() {
    local RESCUE_INTERFACE=
    local INTERFACE_DEVICE_PATH=
    local UDEVADM_PROPERTIES_FOR_INTERFACE=
    local EXPECTED_INTERFACE=
    local NIXOS_INTERFACE=
    # Find the name of the network interface that connects us to the Internet.
    # Inspired by https://unix.stackexchange.com/questions/14961/how-to-find-out-which-interface-am-i-using-for-connecting-to-the-internet/302613#302613
    RESCUE_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)')

    # Find what its name will be under NixOS, which uses stable interface names.
    # See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
    # NICs for most Hetzner servers are not onboard, which is why we use
    # `ID_NET_NAME_PATH`otherwise it would be `ID_NET_NAME_ONBOARD`.
    INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*${RESCUE_INTERFACE})")
    UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
    EXPECTED_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_PATH=\w+' | cut -d= -f2)

    # The above gives us (expectedly) something like `enp0s3`. Hetzner
    # cloud instances seem to omit the p0. So if we match enp0s\d+, we
    # drop the p0.
    # shellcheck disable=SC2001
    NIXOS_INTERFACE="$(echo "$EXPECTED_INTERFACE" | sed 's/^enp0\(s[[:digit:]]\+\)$/en\1/')"
    echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'" 1>&2
    echo "$NIXOS_INTERFACE"
}

function getPrivateInterface() {
    local RESCUE_INTERFACE=
    local INTERFACE_DEVICE_PATH=
    local UDEVADM_PROPERTIES_FOR_INTERFACE=
    local EXPECTED_INTERFACE=
    local NIXOS_INTERFACE=
    # Find the name of the network interface that connects us to the Internet.
    # Inspired by https://unix.stackexchange.com/questions/14961/how-to-find-out-which-interface-am-i-using-for-connecting-to-the-internet/302613#302613
    RESCUE_INTERFACE=$(ip route get 8.8.8.8 | grep -Po '(?<=dev )(\S+)')

    # Find what its name will be under NixOS, which uses stable interface names.
    # See https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/#comment-545626
    # NICs for most Hetzner servers are not onboard, which is why we use
    # `ID_NET_NAME_PATH`otherwise it would be `ID_NET_NAME_ONBOARD`.
    INTERFACE_DEVICE_PATH=$(udevadm info -e | grep -Po "(?<=^P: )(.*eth\d+)" | grep -v "/${RESCUE_INTERFACE}$")
    UDEVADM_PROPERTIES_FOR_INTERFACE=$(udevadm info --query=property "--path=$INTERFACE_DEVICE_PATH")
    EXPECTED_INTERFACE=$(echo "$UDEVADM_PROPERTIES_FOR_INTERFACE" | grep -o -E 'ID_NET_NAME_PATH=\w+' | cut -d= -f2)

    # The above gives us (expectedly) something like `enp0s3`. Hetzner
    # cloud instances seem to omit the p0. So if we match enp0s\d+, we
    # drop the p0.
    # shellcheck disable=SC2001
    NIXOS_INTERFACE="$(echo "$EXPECTED_INTERFACE" | sed 's/^enp0\(s[[:digit:]]\+\)$/en\1/')"
    echo "Determined NIXOS_INTERFACE as '$NIXOS_INTERFACE'" 1>&2
    echo "$NIXOS_INTERFACE"
}

function writeConfig() {
    local hostname="$1"
    local domain="$2"
    local publicInterface="$3"
    local privateInterface="$4"
    local privateIp="$5"
    # Extend/override default `configuration.nix`:
    cat <<EOF >/mnt/etc/nixos/configuration.nix
# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.systemd-boot.enable = true;
  boot.loader.grub.enable = true;
  boot.loader.grub.version = 2;
  boot.loader.grub.devices = [ "/dev/sda" ];
  boot.loader.grub.enableCryptodisk = true;

  boot.initrd.availableKernelModules = [ "virtio_net" "virtio" ];
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
      authorizedKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+CPpHwa9vkV+AyL+Nv4cDphhTssu9ub0+AzpAjQv0G sjagoe@simon-x1"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC/64+VByIx/GYRUZz/wtban8TNafCAw40tC+El+FNNFEDDdXenlXm3KuHDFYun1wsDhdSdUPiNC9kKouFe8OiHWV/htiGuu/oj+GfLpyn3VmyxANRdpgLEXCSPCUNOS66lo0DeilWjoFCt0lm3dCaS4lIzG8BmoRpbh21R37c5D59eqlepg3txT0gBPNhTjuC9Pwy9xaxyNsQxGA2TzT/WljYrDeqlc8ZFpIX2XaHzLQOAETiMYIb9sCdA3pgMbkNzRoFNyM7PNREcYzihKRG4Rt/I26gu++RWrfm9bINV58TkVZJ4FEtThDZFFNu4M7ZrZpPWIUuPaFK57km3+q5Bppj2KfGvGLAr3WzR0+hj7JPO9jOFlzUFmKsRoBpvsi6NlxPsYtphzdLOozlr+EVYRLKTcztpb46dI9RO/lsET0MQ/k/9U3eVv18KgMjMWy+1LalQhF5Ift+qT4m5nAPQSK190wInNC+g0eW1Dm97YbgpCEEd6gr2Qsm0Xk6b2e3Az6WKffoWcyJQY84gWa8UicyHwwVU698IZgJNdJQyTXtJxOMgduixsHFV6L4w3cLEMYXhIJ33w4F8HeqYIsT9Hi55EimCTPVjggCDw2cT7B0Ss51hQhLgtGhNxKYT9t2IOedf6gPZlkn0NM+2dYKQATkhzA0jQcCkiZ7d3B/KlQ== sjagoe@simon-x1"
      ];
    };
  };

  networking.hostName = "$hostname"; # Define your hostname.
  networking.domain = "$domain";
  # networking.hostId = "\$hostid";
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;
  networking.interfaces.$publicInterface.useDHCP = true;
  networking.interfaces.$privateInterface = {
    useDHCP = false;
    ipv4.addresses = [
      {
        address = "${privateIp//\/*/}";
        prefixLength = ${privateIp//*\//};
      }
    ];
  };

  networking.firewall = {
    allowedTCPPorts = pkgs.lib.mkForce [];
    allowedUDPPorts = pkgs.lib.mkForce [];
    interfaces = {
      $publicInterface.allowedTCPPorts = [ 22 ];
      $publicInterface.allowedUDPPorts = [];
      $privateInterface.allowedTCPPorts = [];
      $privateInterface.allowedUDPPorts = [];
    };
  };
  # Ensure wireguard kernel module is available on first boot
  networking.wireguard.enable = true;

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    keyMap = "uk";
  };

  # Set your time zone.
  time.timeZone = "Etc/UTC";

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  # environment.systemPackages = with pkgs; [
  #   wget vim
  # ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  #   pinentryFlavor = "gnome3";
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "$SYSTEM_STATE_VERSION"; # Did you read the comment?

  services = {
    openssh = {
      enable = true;
      permitRootLogin = "prohibit-password";
      passwordAuthentication = false;
      challengeResponseAuthentication = false;
    };
  };

  nix.trustedUsers = [ "sjagoe" ];
  security.sudo.wheelNeedsPassword = false;
  users.users = {
    sjagoe = {
      isNormalUser = true;
      home = "/home/sjagoe";
      extraGroups = [ "wheel" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+CPpHwa9vkV+AyL+Nv4cDphhTssu9ub0+AzpAjQv0G sjagoe@simon-x1"
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC/64+VByIx/GYRUZz/wtban8TNafCAw40tC+El+FNNFEDDdXenlXm3KuHDFYun1wsDhdSdUPiNC9kKouFe8OiHWV/htiGuu/oj+GfLpyn3VmyxANRdpgLEXCSPCUNOS66lo0DeilWjoFCt0lm3dCaS4lIzG8BmoRpbh21R37c5D59eqlepg3txT0gBPNhTjuC9Pwy9xaxyNsQxGA2TzT/WljYrDeqlc8ZFpIX2XaHzLQOAETiMYIb9sCdA3pgMbkNzRoFNyM7PNREcYzihKRG4Rt/I26gu++RWrfm9bINV58TkVZJ4FEtThDZFFNu4M7ZrZpPWIUuPaFK57km3+q5Bppj2KfGvGLAr3WzR0+hj7JPO9jOFlzUFmKsRoBpvsi6NlxPsYtphzdLOozlr+EVYRLKTcztpb46dI9RO/lsET0MQ/k/9U3eVv18KgMjMWy+1LalQhF5Ift+qT4m5nAPQSK190wInNC+g0eW1Dm97YbgpCEEd6gr2Qsm0Xk6b2e3Az6WKffoWcyJQY84gWa8UicyHwwVU698IZgJNdJQyTXtJxOMgduixsHFV6L4w3cLEMYXhIJ33w4F8HeqYIsT9Hi55EimCTPVjggCDw2cT7B0Ss51hQhLgtGhNxKYT9t2IOedf6gPZlkn0NM+2dYKQATkhzA0jQcCkiZ7d3B/KlQ== sjagoe@simon-x1"
      ];
    };
  };
}
EOF
}

{
    echo "Reading LUKS passphrase from stdin"
    IFS= read -r LUKS_PASSPHRASE

    export SYSTEM_STATE_VERSION="20.09"
    NIXOS_HOSTNAME="$1"
    DOMAIN="$2"
    PRIVATE_IP="$3"
    set +u
    VOLUME_ALREADY_INSTALLED="$4"
    set -u
    export INFO_JSON="/root/$NIXOS_HOSTNAME.json"

    echo "Installing initial requirements"
    installRequirements

    echo "Formatting disk /dev/sda"
    # wipes all data!
    wipeDrive /dev/sda
    partition /dev/sda
    mkfs.vfat -F32 -n BOOT "/dev/sda1"
    recordDeviceUUID "/dev/sda1" filesystem

    luksFormat /dev/sda2 cryptroot CRYPTROOT
    recordDeviceUUID "/dev/sda2" luks
    recordDeviceUUID "/dev/mapper/cryptroot" filesystem
    if [ -b /dev/sdb ]; then
        if [[ "$VOLUME_ALREADY_INSTALLED" != "true" ]]; then
            wipeDrive /dev/sdb
            luksFormat /dev/sdb data DATA-VOLUME
        else
            echo -n "$LUKS_PASSPHRASE" | cryptsetup -d - open /dev/sdb data
        fi
        recordDeviceUUID "/dev/sdb" luks
        recordDeviceUUID "/dev/mapper/data" filesystem
    fi

    mount /dev/mapper/cryptroot /mnt
    mkdir /mnt/boot
    mount /dev/sda1 /mnt/boot

    if [ -b /dev/sdb ]; then
        mkdir -p /mnt/data
        mount /dev/mapper/data /mnt/data
    fi

    mkdir -p /mnt/etc/secrets/initrd
    mkdir -p /mnt/etc/ssh

    installNix
    addChannel
    generateConfig
    NIXOS_INTERFACE="$(getPublicInterface)"
    PRIVATE_INTERFACE="$(getPrivateInterface)"

    recordInterface "$NIXOS_INTERFACE" "public"
    recordInterface "$PRIVATE_INTERFACE" "internal"

    writeConfig "$NIXOS_HOSTNAME" "$DOMAIN" "$NIXOS_INTERFACE" "$PRIVATE_INTERFACE" "$PRIVATE_IP"
}
