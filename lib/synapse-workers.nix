{ pkgs, config, lib,
  synapsePort, replicationPort, configFile, logConfigFile, matrixHome, synapseHost
}:
let
  importJSON = import ./import-json.nix;
  workersConfig = importJSON ../synapse-workers.json;

  metricsOffset = 1200;
  metricsIp = synapseHost.ipv4.wireguard.address;
  nameWorker = workerType: workerPort: "matrix-synapse-${workerType}-worker-${toString workerPort}";
  makeWorkerConfig = workerApp: workerName: listenPort: metricsPort:
    ''
      worker_app: "${workerApp}"
      worker_name: "${workerName}"

      worker_replication_host: "127.0.0.1"
      worker_replication_http_port: ${toString replicationPort}

      worker_listeners:
    '' + (lib.optionalString (listenPort > 0) ''
      - type: "http"
        bind_address: "127.0.0.1"
        port: ${toString listenPort}
        x_forwarded: true
        resources:
          - names:
            - "client"
            - "federation"
    '') + ''
      - type: "metrics"
        bind_address: "${metricsIp}"
        port: ${toString metricsPort}

      worker_main_http_uri: "http://127.0.0.1:${toString synapsePort}"
      worker_log_config: "${logConfigFile}"
    '';
  systemdUnit = workerName: entrypoint: workerConfigFile:
    let
      cfg = config.services.matrix-synapse;
      workerArgs = lib.concatMapStringsSep "\n  " (x: "--config-path ${x} \\")
        ([ configFile ] ++ cfg.extraConfigFiles ++ [ workerConfigFile ]);
    in
      {
        description = "matrix-synapse worker ${workerName}";
        partOf = [ "matrix-synapse.target" ];
        after = [ "openssh.service" "matrix-synapse.service" "homeserver.signing.key-key.service" "synapse-config-key.service" ];
        wants = [ "matrix-synapse.service" "homeserver.signing.key-key.service" "synapse-config-key.service" ];
        wantedBy = [ "matrix-synapse.target" ];
        environment = config.systemd.services.matrix-synapse.environment;
        serviceConfig = {
          Type = "notify";
          NotifyAccess = "main";
          User = "matrix-synapse";
          Group = "matrix-synapse";
          WorkingDirectory = matrixHome;
          ExecStart = ''
            ${cfg.package}/bin/${entrypoint} \
              ${workerArgs}
              --keys-directory ${cfg.dataDir}
          '';
          ExecReload = "${pkgs.utillinux}/bin/kill -HUP $MAINPID";
          Restart = "on-failure";
          SyslogIdentifier = "matrix-synapse-${workerName}";
        };
      };

  makeListenerSystemd = entrypoint: workerName: workerPort:
    let
      workerConfig = workerName: listenPort:
        (makeWorkerConfig "synapse.app.${entrypoint}"
          workerName listenPort (listenPort + metricsOffset));
      workerConfigFile = pkgs.writeText "${workerName}.yaml"
        (workerConfig workerName workerPort);
    in
      { name = workerName;
        value = systemdUnit workerName entrypoint workerConfigFile;
      };

  entrypoints = {
    generic_worker = "generic_worker";
    user_dir = "user_dir";
    frontend_proxy = "frontend_proxy";
    federation_sender = "federation_sender";
  };
  makeListenerWorker = entrypoint: workerType: workerPort:
    let
      workerName = nameWorker workerType workerPort;
    in
      {
        inherit workerType;
        inherit workerName;
        inherit workerPort;
        metricsPort = workerPort + metricsOffset;
        systemdService = makeListenerSystemd entrypoint workerName workerPort;
      };
  makeBackgroundWorker = workerType: entrypoint: index:
    let
      workerName = nameWorker workerType index;
      workerPort = 0;
      metricsPort = 9189 + index;

      workerConfig = workerName: listenPort:
        (makeWorkerConfig "synapse.app.${entrypoint}"
          workerName listenPort metricsPort);
      workerConfigFile = pkgs.writeText "${workerName}.yaml"
        (workerConfig workerName workerPort);
    in
      {
        inherit workerType workerName workerPort metricsPort;
        systemdService = {
          name = workerName;
          value = systemdUnit workerName entrypoint workerConfigFile;
        };
      };

  allWorkerPorts = builtins.concatLists
    (pkgs.lib.mapAttrsFlatten (name: value: value.ports) workersConfig.listeners);

  listeners =
    let
      makeWorker' = config:
        map (makeListenerWorker config.entrypoint config.name) config.ports;
    in
      builtins.concatMap makeWorker'
        (lib.mapAttrsFlatten (k: v: ({name = k;} // v)) workersConfig.listeners);

  federationSenders =
    let
      makeWorker' = null;
      name = "federation-sender";
      config = builtins.getAttr name workersConfig.background;
    in
      map (makeBackgroundWorker name config.entrypoint) (lib.range 1 config.count);

  backgroundWorkers = federationSenders;
in
{
  inherit workersConfig allWorkerPorts backgroundWorkers listeners federationSenders;
  allMetricsPorts =
    (map (p: p + metricsOffset) allWorkerPorts)
    ++ (map (w: w.metricsPort) backgroundWorkers);
  metricsPort = port: port + metricsOffset;

  allWorkers = listeners ++ backgroundWorkers;
}
