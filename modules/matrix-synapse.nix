{ name, config, pkgs, lib, ... }:
let
  cfg = config.services.matrix-synapse;
  readHostData = import ../lib/read-host-data.nix;
  networkInfo = import ../lib/network-info.nix;
  secrets = import ../lib/global-secrets.nix;
  inherit (readHostData) allHosts;
  host = readHostData.info name;
  publicInterface = host.interfaces.public;
  wireguardIp = host.ipv4.wireguard.address;

  isRealHomeServer = networkInfo.synapse.homeserver != networkInfo.synapse.baseUrl;
  homeserverDomain = if (isRealHomeServer) then
    networkInfo.synapse.homeserver else null;

  redisHost =
    let
      redisNamePattern = "^redis[[:digit:]]+\.${config.networking.domain}$";
    in
      builtins.head
        (builtins.filter
          (node: (builtins.match redisNamePattern node.fqdn) != null)
          allHosts);

  synapsePort = 8008;
  synapseExtraConfig =
    let
      joinYaml = sep: items:
        sep + builtins.concatStringsSep "\n${sep}" items;
      joinYamlMap = joinYaml "  ";
      joinYamlList = joinYaml "  - ";
      trustedKeyServers = joinYamlList
        (map builtins.toJSON networkInfo.synapse.trustedServers);
      oldSigningKeys =
        let
          oldKeys = secrets.synapse.oldSigningKeys;
        in
          joinYamlMap
            (map (n: "\"${n}\": ${builtins.toJSON oldKeys.${n}}")
              (builtins.attrNames oldKeys));
      federationSenders = joinYamlList
        (map (w: w.workerName) workers.federationSenders);
      autoJoinRooms = joinYamlList (map builtins.toJSON networkInfo.autoJoinRooms);
    in
      ''
        # turn_allow_guests: true
        auto_join_rooms:
        ${autoJoinRooms}
        presence:
          enabled: false
        old_signing_keys:
        ${oldSigningKeys}
        trusted_key_servers:
        ${trustedKeyServers}
      '' + (pkgs.lib.optionalString ((builtins.length workers.workersConfig.listeners.user-dir.ports) > 0) ''
        update_user_directory: False
      '') + (pkgs.lib.optionalString ((builtins.length workers.federationSenders) > 0) ''
        send_federation: False
        federation_sender_instances:
        ${federationSenders}
      '');

  replicationPort = 9093;
  # WARNING: This should have some client identifier hashing to direct
  # users to a stable backend.
  # For now it must not be more than one worker!

  mainMetricsPort = 9200;

  logConfigFile = pkgs.writeText "log_config.yaml" cfg.logConfig;
  configFile = import ../lib/matrix-config.nix {
    inherit pkgs lib cfg logConfigFile;
  };
  matrixHome = "/data/matrix-synapse";
  synapseEnabled = true;

  workers = import ../lib/synapse-workers.nix {
    inherit pkgs config lib;
    inherit synapsePort replicationPort configFile logConfigFile matrixHome;
    synapseHost = host;
  };

  synapseWorkers =
    (builtins.listToAttrs (map (w: w.systemdService) (workers.allWorkers)));

  telegrafInputs = import ../lib/telegraf-inputs.nix;
in
{
  imports = [
    ./telegraf.nix
    ./postgres-haproxy.nix
  ];

  services.telegraf.extraConfig.inputs =
    telegrafInputs // {
      nginx = [{
        urls = ["http://127.0.0.1:8001/server_status"];
      }];
    };

  deployment.keys.hetzner-dns-api-key = {
    text = secrets.hetznerDNS.token;
    user = "acme";
  };
  deployment.keys."homeserver.signing.key" = {
    destDir = "/data/matrix-synapse";
    text = secrets.synapse.signingKey + "\n";
    ${if (synapseEnabled) then "user" else null} = "matrix-synapse";
  };
  deployment.keys.pgbouncer-userlist = {
    text = ''"matrix_synapse" "${secrets.postgres.matrix_synapse}"'';
    user = "pgbouncer";
  };

  deployment.keys.synapse-config = {
    text = ''
      admin_contact: "${secrets.synapse.adminContact}"
      worker_replication_secret: "${secrets.synapse.workerReplicationSecret}"
      turn_shared_secret: "${secrets.coturn.sharedSecret}"
      registration_shared_secret: "${secrets.synapse.registrationSecret}"
      database:
        name: psycopg2
        args:
          user: matrix_synapse
          password: "${secrets.postgres.matrix_synapse}"
          database: matrix_synapse
          host: localhost
          port: "6432"
          cp_min: 5
          cp_max: 10
          keepalives_idle: 10
          keepalives_interval: 10
          keepalives_count: 3
      redis:
        enabled: true
        host: ${redisHost.ipv4.wireguard.address}
        port: 6379
        password: ${secrets.redis.requirePass}
      email:
        smtp_host: "${networkInfo.aws.sesEndpoint}"
        smtp_port: ${networkInfo.aws.smtpPort}
        smtp_user: "${secrets.aws.ses.username}"
        smtp_pass: "${secrets.aws.ses.password}"
        notif_from: "%(app)s Matrix homeserver <noreply@${networkInfo.maildomain}>"
        app_name: "${networkInfo.domain}"
        notif_for_new_users: false
        enable_notifs: false
        invite_client_location: "https://${networkInfo.element.baseUrl}"
    '';
    ${if (synapseEnabled) then "user" else null} = "matrix-synapse";
  };
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
          networkInfo.synapse.baseUrl
          networkInfo.element.baseUrl
        ] ++ pkgs.lib.optional (isRealHomeServer) networkInfo.synapse.homeserver;
      };
    };
  };

  users.users.matrix-synapse.createHome = true;
  users.users.matrix-synapse.home = pkgs.lib.mkForce matrixHome;
  users.groups.keys.members = [ "acme" "pgbouncer" ] ++ pkgs.lib.optional synapseEnabled  "matrix-synapse";

  networking.firewall.interfaces."${publicInterface}".allowedTCPPorts = [ 80 443 ];
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ mainMetricsPort ] ++ workers.allMetricsPorts;

  services.nginx =
    let
      nameUpstream = name: builtins.replaceStrings ["-"] ["_"] name;
      listenerWorkers = lib.mapAttrsFlatten (k: v: ({name = k;} // v)) workers.workersConfig.listeners;
    in
    {
      enable = true;
      appendHttpConfig =
        let
          makeBackends = ports:
            let
              sep = "  ";
            in
              sep + (builtins.concatStringsSep "\n${sep}"
                (map (port: "server localhost:${toString port};") ports));
          makeUpstream = config: ''
            upstream ${nameUpstream config.name} {
              ${lib.optionalString (builtins.hasAttr "hash" config) "${config.hash};"}
              ${makeBackends config.ports}
            }
          '';
          upstreams =
            lib.concatMapStringsSep "\n" makeUpstream listenerWorkers;
        in
          ''
            upstream synapse_main {
              server localhost:${toString synapsePort};
            }
            ${upstreams}
          '';

      virtualHosts = {
        ${homeserverDomain} = {
          default = false;
          forceSSL = true;
          useACMEHost = name;
          extraConfig = ''
            location = /robots.txt {
                allow all;
                add_header Content-Type text/plain;
                return 200 "User-agent: *\nDisallow: /\n";
            }
            '' + (pkgs.lib.optionalString networkInfo.synapse.enableFederation ''
            location = /.well-known/matrix/server {
                allow all;
                return 200 '{"m.server": "${networkInfo.synapse.baseUrl}:443"}';
                default_type application/json;
                add_header Access-Control-Allow-Origin *;
            }
            '') + ''
            location = /.well-known/matrix/client {
                allow all;
                return 200 '{"m.homeserver": {"base_url": "https://${networkInfo.synapse.baseUrl}"}}';
                default_type application/json;
                add_header Access-Control-Allow-Origin *;
            }
            location / {
                allow all;
          '' + (if networkInfo.website.enable then ''
                root ${pkgs.vectornet-web};
          '' else ''
                return 302 https://${networkInfo.element.baseUrl};
          '') + ''
            }
          '';
        };
        "${networkInfo.synapse.baseUrl}" = {
          forceSSL = true;
          useACMEHost = name;
          extraConfig =
            let
              proxy' = backend: match: (proxy match backend);
              proxy = match: backend: ''
                location ~* ${match} {
                    allow all;
                    proxy_pass http://${backend};
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                    proxy_set_header Host $host;
                    proxy_set_header X-Forwarded-Proto $scheme;
                    proxy_set_header X-Real-IP $remote_addr;
                    proxy_set_header Upgrade $http_upgrade;
                    proxy_set_header Connection $connection_upgrade;
                    proxy_buffering off;

                    client_max_body_size 10M;
                }
              '';
              makeWorkerProxies = config:
                lib.concatMapStringsSep "\n" (proxy' (nameUpstream config.name)) config.routes;

              workerProxies = lib.concatMapStringsSep "\n" makeWorkerProxies listenerWorkers;
            in
            ''
              location = /robots.txt {
                  allow all;
                  add_header Content-Type text/plain;
                  return 200 "User-agent: *\nDisallow: /\n";
              }
              '' + (pkgs.lib.optionalString networkInfo.synapse.enableFederation ''
              location = /.well-known/matrix/server {
                  allow all;
                  return 200 '{"m.server": "${networkInfo.synapse.baseUrl}:443"}';
                  default_type application/json;
                  add_header Access-Control-Allow-Origin *;
              }
              '') + ''
              location = /.well-known/matrix/client {
                  return 200 '{"m.homeserver": {"base_url": "https://${networkInfo.synapse.baseUrl}"}}';
                  default_type application/json;
                  add_header Access-Control-Allow-Origin *;
              }
              # Locations from https://github.com/matrix-org/synapse/blob/develop/docs/workers.md
              ${workerProxies}
              # Fallback to the main process
              ${proxy "^(\/_matrix|\/_synapse\/client)" "synapse_main"}
              # TODO get health of all workers for external healthcheck
              ${proxy "^/health$" "synapse_main"}
              location / {
                  allow all;
                  return 404;
              }
            '';
        };
        "${networkInfo.element.baseUrl}" = {
          forceSSL = true;
          useACMEHost = name;
          locations."/" = {
            root = pkgs.element-web;
          };
          extraConfig = ''
            location = /robots.txt {
                allow all;
                add_header Content-Type text/plain;
                return 200 "User-agent: *\nDisallow: /\n";
            }
          '';
        };
        localhost = {
          listen = [
            { addr = "127.0.0.1";
              port = 8001;
            }
          ];
          extraConfig = ''
            location = /server_status {
                allow 127.0.0.0/8;
                deny all;
                stub_status;
            }
          '';
        };
      };
      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedTlsSettings = true;
    };

  services.matrix-synapse =
    {
      enable = synapseEnabled;
      # Terminating TLS in nginx above, and only listening on localhost here.
      no_tls = true;
      # This is overridden by deployment.keys.synapse-config
      # We specify sqlite3 here to work around an assertion in the
      # matrix-synapse nix module that asserts a localhost db address
      # has the postgres service running locally.
      # Our deployment uses localhost to connect to a remote postgres
      # cluster via a local haproxy instance; the assertion just gets
      # in the way.
      database_type = "sqlite3";
      extraConfig = synapseExtraConfig;
      extraConfigFiles = [
        "/run/keys/synapse-config"
      ];
      public_baseurl = "https://${networkInfo.synapse.baseUrl}";
      server_name = "${networkInfo.synapse.homeserver}";
      enable_registration = networkInfo.synapse.enableRegistration;
      max_upload_size = "10M";
      dataDir = matrixHome;
      enable_metrics = true;
      listeners = [
        {
          bind_address = "127.0.0.1";
          port = synapsePort;
          tls = false;
          type = "http";
          x_forwarded = true;
          resources = [
            {
              # Let nginx handle compression
              compress = false;
              names = [ "client" ];
            }
          ] ++ pkgs.lib.optional networkInfo.synapse.enableFederation
            {
              # Let nginx handle compression
              compress = false;
              names = [ "federation" ];
            };
        }
        {
          bind_address = "127.0.0.1";
          port = replicationPort;
          tls = false;
          type = "http";
          resources = [{ compress = false; names = [ "replication" ]; }];
        }
        {
          bind_address = wireguardIp;
          port = mainMetricsPort;
          tls = false;
          type = "http";
          resources = [{ compress = false; names = [ "metrics" ]; }];
        }
      ];
      turn_user_lifetime = "1h";
      turn_uris = [
        "turns:${networkInfo.turn.baseUrl}?transport=udp"
        "turns:${networkInfo.turn.baseUrl}?transport=tcp"
        "turn:${networkInfo.turn.baseUrl}?transport=udp"
        "turn:${networkInfo.turn.baseUrl}?transport=tcp"
      ];
    };

  systemd.targets.matrix-synapse = {
    description = "Synapse parent target";
    after = [ "networking.target" "openssh.service" "wireguard-wg0.service" "homeserver.signing.key-key.service" "synapse-config-key.service" ];
    wants = [ "wireguard-wg0.service" "homeserver.signing.key-key.service" "synapse-config-key.service" ];
    wantedBy = [ "multi-user.target" ];
  };

  users.groups.pgbouncer.gid = 799;
  users.users.pgbouncer = {
    description = "pgbouncer daemon user";
    uid = 799;
    group = "pgbouncer";
  };

  systemd.services = {
    pgbouncer =
      let
        stateDir = "pgbouncer";
        workingDir = "/var/lib/${stateDir}";
        configFile = pkgs.writeText "pgbouncer.ini" ''
          [databases]
          matrix_synapse = host=localhost port=5432 dbname=matrix_synapse

          [pgbouncer]
          listen_port = 6432
          listen_addr = localhost
          auth_type = scram-sha-256
          auth_file = /run/keys/pgbouncer-userlist
          pidfile = ${workingDir}/pgbouncer.pid

          pool_mode = transaction

          max_client_conn = 400
          default_pool_size = 40
          max_db_connections = 50
        '';
        dependantUnits = [ "matrix-synapse.service" ] ++
                         (map (l: "${l.workerName}.service") workers.allWorkers);
      in
      {
        wantedBy = [ "multi-user.target" ] ++ dependantUnits;
        before = dependantUnits;
        after = [ "network.target" "haproxy.service" "pgbouncer-userlist-key.service" ];
        wants = [ "pgbouncer-userlist-key.service" "haproxy.service" ];
        serviceConfig = {
          ExecStart = "${pkgs.pgbouncer}/bin/pgbouncer ${configFile}";
          User = "pgbouncer";
          Restart = "always";
          WorkingDirectory = workingDir;
          StateDirectory = stateDir;
          LimitNOFILE = 4096;
        };
      };
    matrix-synapse = {
      wantedBy = lib.mkForce [ "matrix-synapse.target" ];
      after = [ "openssh.service" "homeserver.signing.key-key.service" "synapse-config-key.service" ];
      wants = [ "homeserver.signing.key-key.service" "synapse-config-key.service" ];
      serviceConfig = {
        LimitNOFILE = networkInfo.synapse.ulimit.nofile;
        ExecStart = lib.mkForce ''
        ${cfg.package}/bin/homeserver \
          ${ lib.concatMapStringsSep "\n  " (x: "--config-path ${x} \\") ([ configFile ] ++ cfg.extraConfigFiles) }
          --keys-directory ${cfg.dataDir}
      '';
      };
      preStart = lib.mkForce ''
      ${cfg.package}/bin/homeserver \
          --config-path ${configFile} \
          --keys-directory ${cfg.dataDir} \
          --generate-keys
    '';
    };
  } // synapseWorkers;

  environment.systemPackages = [
    pkgs.element-web
  ] ++ (lib.optional networkInfo.website.enable pkgs.vectornet-web);

  nixpkgs.overlays = [
    (self: super: {
      txredisapi = pkgs.python3.pkgs.buildPythonPackage rec {
        pname = "txredisapi";
        version = "1.4.7";

        src = pkgs.python3.pkgs.fetchPypi {
          inherit pname version;
          sha256 = "1fqjr2z3wqgapa2fbxkr4vcf33ql1v9cgy58vjmhimim3vsl7k76";
        };
        propagatedBuildInputs = [ pkgs.python3.pkgs.six pkgs.python3.pkgs.twisted ];

        doCheck = false;
        pythonImportsCheck = [ "txredisapi" ];

        meta = with lib; {
          description = "non-blocking redis client for python twisted";
          homepage = "https://github.com/IlyaSkriblovsky/txredisapi";
          license = licenses.asl20;
          maintainers = with maintainers; [ sjagoe ];
        };
      };
      # Needed txredisapi>=1.4.7 for the 'redis' feature but it was
      # not installed (also hiredis because now we're not using the
      # baked-in option of enableRedis in the build)
      matrix-synapse = super.matrix-synapse.overrideAttrs (old: {
        propagatedBuildInputs = with pkgs.python3.pkgs;
          old.propagatedBuildInputs ++ [
            hiredis
            self.txredisapi
          ];
        patches = old.patches ++ [
          ../patches/0001-Add-all-entrypoints.patch
        ];
      });
    })
    (self: super: {
      element-web = super.element-web.override {
        conf = {
          default_server_config = {
            "m.homeserver" = {
              base_url = "https://${networkInfo.synapse.baseUrl}";
              server_name = "${networkInfo.synapse.homeserver}";
            };
            # "m.identity_server" = {
            #   base_url = "https://vector.im";
            # };
          };
          # jitsi.preferredDomain = "${networkInfo.jitsi.baseUrl}";
        };
      };
    })]
  ++ (lib.optional networkInfo.website.enable (self: super: {
    vectornet-web =
      super.stdenv.mkDerivation {
        pname = "vectornet-web";
        version = "0.0.1";
        src = ../pkgs/site/src;

        buildInputs = [ super.hugo ];

        installPhase = ''
            runHook preInstall

            mkdir -p $out/
            hugo --destination=$out/

            runHook postInstall
          '';

        meta = with lib; {
          description = "The ${networkInfo.domain} matrix homeserver website";
          homepage = "https://${networkInfo.domain}/";
          maintainers = with maintainers; [ sjagoe ];
        };
      };
  }));
}
