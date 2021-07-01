{ name, config, pkgs, lib, ...}:
let
  readHostData = import ../lib/read-host-data.nix;
  networkInfo = import ../lib/network-info.nix;
  secrets = import ../lib/global-secrets.nix;

  host = readHostData.info name;
  privateIp = host.ipv4.internal.address;
  wireguardIp = host.ipv4.wireguard.address;
  publicInterface = host.interfaces.public;

  metricsPort = networkInfo.metrics.metricsPort;
  inputs = import ../lib/telegraf-inputs.nix;
in
{
  imports = [
    ./telegraf.nix
    ./prometheus.nix
  ];

  deployment.keys.hetzner-dns-api-key = {
    text = secrets.hetznerDNS.token;
    user = "acme";
  };
  deployment.keys.smtp-password = {
    text = "${secrets.aws.ses.password}";
    user = "grafana";
  };
  users.groups.keys.members = [ "acme" "grafana" ];

  security.acme = {
    acceptTerms = true;
    email = secrets.acmeEmail;
    certs = {
      "${name}" = {
        dnsProvider = "hetzner";
        credentialsFile = pkgs.writeText "certbotCredentialsFile" "HETZNER_API_KEY_FILE=/run/keys/hetzner-dns-api-key";
        email = secrets.acmeEmail;
        group = "nginx";
        extraDomainNames = [
          networkInfo.metrics.publicDomain
        ];
      };
    };
  };

  networking.firewall.interfaces."${publicInterface}".allowedTCPPorts = [ 80 443 ];
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ metricsPort ];

  systemd.services.influxdb.after = [ "openssh.service" ];
  systemd.services.telegraf = {
    after = [ "openssh.service" "influxdb.service" ];
    wants = [ "influxdb.service" ];
  };
  systemd.services.grafana = {
    after = [ "openssh.service" "influxdb.service" "smtp-password-key.service" ];
    wants = [ "influxdb.service" "smtp-password-key.service" ];
  };

  services.influxdb = {
    enable = true;
    dataDir = "/data/influxdb";
  };
  # Deploy influx and configure the database before deploying anything
  # else.
  services.telegraf = {
    # enable = lib.mkForce false;
    extraConfig = {
      outputs = lib.mkForce {
        influxdb = [
          { urls = [ "http://localhost:8086" ];
            database = "telegraf";
            skip_database_creation = true;
          }
        ];
      };
      inputs = inputs // {
        socket_listener = [
          { service_address = "tcp://${wireguardIp}:${toString metricsPort}";
            data_format = "influx";
            # FIXME TLS?
          }
        ];
      };
    };
  };

  services.grafana = {
    enable = true;
    dataDir = "/data/grafana";
    domain = "${networkInfo.metrics.publicDomain}";
    rootUrl = "https://%(domain)s";
    protocol = "http";
    smtp.enable = true;
    smtp.fromAddress = "grafana@${networkInfo.maildomain}";
    smtp.host = "${networkInfo.aws.sesEndpoint}:${toString networkInfo.aws.smtpPort}";
    smtp.user = "${secrets.aws.ses.username}";
    smtp.passwordFile = "/run/keys/smtp-password";
    extraOptions =
      { DATE_FORMATS_INTERVAL_HOUR = "DD/MM HH:mm";
        DATE_FORMATS_INTERVAL_DAY = "DD/MM";
      };
  };

  services.nginx = {
    enable = true;
    virtualHosts = {
      "${networkInfo.metrics.publicDomain}" = {
        forceSSL = true;
        useACMEHost = name;
        extraConfig = ''
          location = /robots.txt {
              allow all;
              add_header Content-Type text/plain;
              return 200 "User-agent: *\nDisallow: /\n";
          }
          location / {
              allow all;
              proxy_pass http://localhost:3000;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header Host $host;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection $connection_upgrade;
              proxy_buffering off;
          }
        '';
      };
    };
  };

  environment.systemPackages = [ pkgs.influxdb ];
}
