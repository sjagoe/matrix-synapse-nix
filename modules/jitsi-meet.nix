{ name, config, pkgs, ... }:
let
  networkInfo = import ../lib/network-info.nix;
  secrets = import ../lib/global-secrets.nix;
in
{
  security.acme = {
    acceptTerms = true;
    email = secrets.acmeEmail;
    certs = {
      "${name}" = {
        email = secrets.acmeEmail;
        extraDomainNames = [
          networkInfo.jitsi.baseUrl
        ];
      };
    };
  };

  services.jitsi-meet =
    { enable = false;
      hostName = "${networkInfo.jitsi.baseUrl}";
    };
  services.jitsi-videobridge.openFirewall = true;

  services.nginx =
    {
      enable = false;
      virtualHosts = {
        "${config.services.jitsi-meet.hostName}" = {
          forceSSL = true;
          useACMEHost = name;
          # extraConfig = ''
          #   location = /.well-known/element/jitsi {
          #       default_type application/json;
          #       add_header Access-Control-Allow-Origin *;
          #       return 200 '{"auth":"openidtoken-jwt"}';
          #   }
          # '';
        };
      };
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedTlsSettings = true;
    };
}
