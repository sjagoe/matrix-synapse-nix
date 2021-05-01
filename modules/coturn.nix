{ name, config, pkgs, ... }:
let
  readHostData = import ../lib/read-host-data.nix;
  networkInfo = import ../lib/network-info.nix;
  secrets = import ../lib/global-secrets.nix;

  host = readHostData.info name;
  privateIp = host.ipv4.internal.address;
  wireguardIp = host.ipv4.wireguard.address;

  turnserverConfText = import ../lib/turnserver-conf.nix {
    inherit (pkgs) lib;
    cfg = config.services.coturn;
    staticAuthSecret = secrets.coturn.sharedSecret;
  };
in
{
  deployment.keys.hetzner-dns-api-key = {
    text = secrets.hetznerDNS.token;
    user = "acme";
  };
  deployment.keys."turnserver.conf" = {
    text = turnserverConfText;
    user = "turnserver";
  };
  users.groups.keys.members = [ "acme" "turnserver" ];

  security.acme = {
    acceptTerms = true;
    email = secrets.acmeEmail;
    certs = {
      "${name}" = {
        dnsProvider = "hetzner";
        credentialsFile = pkgs.writeText "certbotCredentialsFile" "HETZNER_API_KEY_FILE=/run/keys/hetzner-dns-api-key";
        email = secrets.acmeEmail;
        group = "turnserver";
        extraDomainNames = [
          "${networkInfo.turn.baseUrl}"
        ];
      };
    };
  };

  networking.enableIPv6 = false;
  networking.firewall.allowedTCPPorts = pkgs.lib.mkForce [ 3478 3479 5349 5350 ];
  networking.firewall.allowedUDPPorts = pkgs.lib.mkForce ([ 3478 3479 5349 5350 ] ++ (pkgs.lib.range 49152 65535));
  networking.firewall.interfaces."${host.interfaces.public}" = {
    allowedTCPPorts = [ 3478 3479 5349 5350 ];
    allowedUDPPorts = [ 3478 3479 5349 5350 ];
  };

  systemd.services.coturn = {
    serviceConfig = {
      ExecStart = pkgs.lib.mkForce "${pkgs.coturn}/bin/turnserver -c /run/keys/turnserver.conf";
    };
    requires = [ "turnserver.conf-key.service" ];
    wants = [ "turnserver.conf-key.service" ];
    after = [ "openssh.service" "turnserver.conf-key.service" ];
  };
  services.coturn =
    let
      certDirectory = config.security.acme.certs."${name}".directory;
    in
    {
      listening-ips = [ host.ipv4.public.address ];
      relay-ips = [ host.ipv4.public.address ];
      enable = true;
      use-auth-secret = true;
      realm = "${networkInfo.turn.baseUrl}";
      no-tcp-relay = true;
      secure-stun = true;
      # no-tls = true;
      # no-dtls = true;
      cert = "${certDirectory}/fullchain.pem";
      pkey = "${certDirectory}/key.pem";
      extraConfig = ''
        user-quota=128
        total-quota=4200
        denied-peer-ip=10.0.0.0-10.255.255.255
        denied-peer-ip=192.168.0.0-192.168.255.255
        denied-peer-ip=172.16.0.0-172.31.255.255

        # special case the turn server itself so that client->TURN->TURN->client flows work
        allowed-peer-ip=${privateIp}
        allowed-peer-ip=${wireguardIp}
      '';
    };
}
