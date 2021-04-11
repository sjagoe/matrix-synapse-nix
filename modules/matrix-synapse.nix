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
      '' + (pkgs.lib.optionalString ((builtins.length workers.ports.userDir) > 0) ''
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
        in
          ''
            upstream synapse_main {
              server localhost:${toString synapsePort};
            }
            upstream synapse_initial_sync {
            ${makeBackends workers.ports.initialSync}
            }
            upstream synapse_client_api {
            ${makeBackends workers.ports.clientApi}
            }
            upstream federation_requests_api {
            ${makeBackends workers.ports.federationRequestsApi}
            }
            upstream inbound_federation_requests_api {
            ip_hash;
            ${makeBackends workers.ports.inboundFederationRequestsApi}
            }
            upstream user_dir_workers {
            ${makeBackends workers.ports.userDir}
            }
            upstream frontend_proxy_workers {
            ${makeBackends workers.ports.frontendProxy}
            }
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
          '' + ( if networkInfo.website.enable then ''
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
              # Sync requests
              ${proxy "^/_matrix/client/(v2_alpha|r0)/sync$" "synapse_initial_sync"}
              ${proxy "^/_matrix/client/(api/v1|v2_alpha|r0)/events$" "synapse_initial_sync"}
              ${proxy "^/_matrix/client/(api/v1|r0)/initialSync$" "synapse_initial_sync"}
              ${proxy "^/_matrix/client/(api/v1|r0)/rooms/[^/]+/initialSync$" "synapse_initial_sync"}
              # Federation requests
              ${proxy "^/_matrix/federation/v1/event/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/state/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/state_ids/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/backfill/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/get_missing_events/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/publicRooms" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/query/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/make_join/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/make_leave/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/send_join/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v2/send_join/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/send_leave/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v2/send_leave/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/invite/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v2/invite/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/query_auth/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/event_auth/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/exchange_third_party_invite/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/user/devices/" "federation_requests_api"}
              ${proxy "^/_matrix/federation/v1/get_groups_publicised$" "federation_requests_api"}
              ${proxy "^/_matrix/key/v2/query" "federation_requests_api"}
              # Inbound federation transaction request
              ${proxy "^/_matrix/federation/v1/send/" "inbound_federation_requests_api"}
              # Client API requests
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/publicRooms$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/rooms/.*/joined_members$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/rooms/.*/context/.*$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/rooms/.*/members$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/rooms/.*/state$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/account/3pid$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/devices$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/keys/query$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/keys/changes$" "synapse_client_api"}
              ${proxy "^/_matrix/client/versions$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/voip/turnServer$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/joined_groups$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/publicised_groups$" "synapse_client_api"}
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/publicised_groups/" "synapse_client_api"}
              # User directory worker
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/user_directory/search$" "user_dir_workers"}
              # Frontend proxy (frequent-access client requests)
              ${proxy "^/_matrix/client/(api/v1|r0|unstable)/keys/upload" "frontend_proxy_workers"}
              # Fallback to the main process
              ${proxy "^(\/_matrix|\/_synapse\/client)" "synapse_main"}
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
      turn_user_lifetime = "86400000";
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
    pkgs.vectornet-web
  ];

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
    })
    (self: super: {
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
    })
  ];
}
