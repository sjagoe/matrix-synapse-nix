{ name, config, pkgs, ... }:
let
  iputils = import ../lib/iputils.nix;
  readHostData = import ../lib/read-host-data.nix;
  secrets = import ../lib/global-secrets.nix;
  networkInfo = import ../lib/network-info.nix;
  networks = networkInfo.networks;

  postgresHome = "/data/postgresql";
  monitoringUser = "telegraf";
  dbname = "matrix_synapse";
  dbuser = dbname;
  host = readHostData.info name;

  repmgr = config.services.postgresql.package.pkgs.repmgr;

  wireguardIp = host.ipv4.wireguard.address;
  repmgrConfig = ''
    node_id=${toString (iputils.hostNumber name)}
    node_name='${config.networking.hostName}'
    conninfo='host=${wireguardIp} user=repmgr dbname=repmgr connect_timeout=2 passfile=/data/postgresql/repmgr-passwd'
    data_directory='${config.services.postgresql.dataDir}'
    repmgr_bindir='${repmgr}/bin'
    pg_bindir='${config.services.postgresql.package}/bin'
    passfile='/data/postgresql/repmgr-passwd'

    failover=automatic
    promote_command='${repmgr}/bin/repmgr standby promote -f /etc/repmgr.conf --log-to-file'
    follow_command='${repmgr}/bin/repmgr standby follow -f /etc/repmgr.conf --log-to-file --upstream-node-id=%n'

    service_start_command='sudo systemctl start postgresql.service'
    service_stop_command='sudo systemctl stop postgresql.service'
    service_restart_command'sudo systemctl restart postgresql.service'
    service_reload_command'sudo systemctl reload postgresql.service'
  '';

  telegrafInputs = import ../lib/telegraf-inputs.nix;
in
# Do some tuning... https://github.com/matrix-org/synapse/blob/develop/docs/postgres.md#tuning-postgres
{
  imports = [
    ./telegraf.nix
  ];
  services.telegraf.extraConfig.inputs =
    let
      address = "host=/run/postgresql/.s.PGSQL.5432 dbname=${dbname} user=${monitoringUser} sslmode=disable";
      databases = [ dbname ];
    in
      telegrafInputs // {
        postgresql = [{
          inherit address;
          inherit databases;
        }];
        postgresql_extensible = [{
          inherit address;
          inherit databases;
          query = [{
            sqlquery = ''SELECT nspname || '.' || relname AS "relation", pg_relation_size(C.oid) AS "size" FROM pg_class C LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace) WHERE nspname NOT IN ('pg_catalog', 'information_schema') ORDER BY pg_relation_size(C.oid) DESC LIMIT 40;'';
            version = 906;
            withdbname = false;
            measurement = "pg_table_size";
            tagvalue = "relation";
          }];
        }];
      };
  # Allow telegraf to connect to postgres with unix socket
  users.groups.postgres.members = [ monitoringUser ];

  deployment.keys.repmgr-passwd = {
    text = ''
      *:*:*:repmgr:${secrets.postgres.repmgr}
    '';
    user = "postgres";
    group = "postgres";
    destDir = "/data/postgresql";
  };
  users.groups.keys.members = [ "postgres" ];

  environment.systemPackages = [
    pkgs.postgresql_12.pkgs.repmgr
  ];
  nixpkgs.overlays = [
    (self: super: {
      postgresql_12 = super.postgresql_12 // {
        pkgs.repmgr = self.lib.overrideDerivation super.postgresql_12.pkgs.repmgr (drv: {
          patches = [ ../patches/repmgr-ssh-test.patch ];
        });
      };
    })
  ];

  environment.etc = {
    "repmgr.conf" = {
      text = repmgrConfig;
      user = "postgres";
      group = "postgres";
      mode = "0440";
    };
  };

  security.sudo.extraRules = [
    {
      users = [ "postgres" ];
      runAs = "root";
      commands = map (command: { options = [ "NOPASSWD" ]; command = "/run/current-system/sw/bin/systemctl ${command} postgresql.service"; })
        [ "start" "stop" "restart" "reload" ];
    }
  ];

  services.postgresql = {
    enable = true;
    enableTCPIP = true;
    package = pkgs.postgresql_12;
    dataDir = "${postgresHome}/${config.services.postgresql.package.psqlSchema}";
    initdbArgs = [
      "-E" "UTF-8"
      "-U" "postgres"
      "--locale=en_US.UTF-8"
    ];
    extraPlugins = with pkgs.postgresql_12.pkgs; [ repmgr ];
    authentication =
      let
        wgNetwork = with networks.wireguard; "${address}/${toString prefixLength}";
      in
        pkgs.lib.mkForce ''
          local all postgres              peer
          local ${dbname} ${monitoringUser} peer

          local replication repmgr              trust
          host  replication repmgr 127.0.0.1/32 scram-sha-256
          host  replication repmgr ${wgNetwork} scram-sha-256

          local repmgr repmgr              trust
          host  repmgr repmgr 127.0.0.1/32 scram-sha-256
          host  repmgr repmgr ${wgNetwork} scram-sha-256

          host  all all      127.0.0.1/32 scram-sha-256
          host  ${dbname} ${dbuser} ${wgNetwork} scram-sha-256
        '';
    settings = {
      password_encryption = "scram-sha-256";
      hot_standby = "on";
      wal_level = "replica";
      max_wal_senders = 10;
      max_replication_slots = 10;
      wal_keep_segments = 30;
      archive_mode = "on";
      archive_command = "/run/current-system/sw/bin/true";
      # Required for repmgrd
      shared_preload_libraries = "repmgr";
      ################
      # Tuning parameters; change for instance sizes
      # https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
      # shared_buffers is Unit of 8kB; this is 2GB or 1/4 of RAM
      # Set these when using larger server
      # effective_cache_size: 2.5x shared_buffers, or ~62% of available RAM
      # work_mem
      # maintenance_work_mem
      # autovacuum_work_mem
    } // networkInfo.postgres."${name}";
  };
  services.postgresqlBackup = {
    enable = true;
    databases = [ dbname ];
    startAt = "${host.postgresBackup.startAt}";
  };

  systemd.services.postgresql = {
    wants = [ "repmgr-passwd-key.service" ];
    after = [ "openssh.service" "repmgr-passwd-key.service" ];
  };

  systemd.sockets.repmgr_role = {
    socketConfig = {
      ListenStream = "${wireguardIp}:9999";
      Accept = true;
    };
    wantedBy = [ "sockets.target" ];
  };

  systemd.services."repmgr_role@" = {
    description = "Service for HAProxy to check node status/role";
    wants = [ "repmgr-passwd-key.service" ];
    serviceConfig = {
      ExecStart = "-${repmgr}/bin/repmgr -f /etc/repmgr.conf --log-level=ERROR node check --role";
      User = "postgres";
      Group = "postgres";
      StandardInput = "socket";
    };
  };

  users.users.postgres.createHome = true;
  users.users.postgres.home = pkgs.lib.mkForce postgresHome;
  networking.firewall.interfaces.wg0 = {
    allowedTCPPorts = [ 5432 9999 ];
    allowedUDPPorts = [];
  };
}
