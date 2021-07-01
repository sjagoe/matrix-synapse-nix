{ name, config, pkgs, lib, ...}:
let
  readHostData = import ../lib/read-host-data.nix;
  inherit (readHostData) allHosts;

  stateDir = "prometheus2";
  sourceDir = "/data/${stateDir}";
  workingDir = "/var/lib/${stateDir}";

  # FIXME: Hardcoded app host
  synapseHost = readHostData.info "vecnetapp1.vectornet.fi";
  # FIXME: Duplicated synapse worker ports
  mainMetricsPort = 9200;

  workers = import ../lib/synapse-workers.nix {
    inherit pkgs config lib;
    inherit synapseHost;
    synapsePort = null;
    replicationPort = null;
    configFile = null;
    logConfigFile = null;
    matrixHome = null;
  };

  mkScrapeConfig = ix: workerSpec:
    let
      job = workerSpec.workerType;
      port = workerSpec.metricsPort;
      index = toString ix;
    in
      { targets = [ "${synapseHost.fqdn}:${toString port}" ];
        labels = { instance = synapseHost.fqdn; inherit job index; };
      };

  mkScrapeConfigs' = workerSpecs:
   lib.imap1 mkScrapeConfig workerSpecs;

  # Apply scrape configs in groups by the worker type to ensure that
  # the worker indexes are correct (all 1-based)
  mkScrapeConfigs = allWorkerSpecs:
    let
      workerGroups = lib.groupBy (w: w.workerType) allWorkerSpecs;
      groupedConfigs = map mkScrapeConfigs' (builtins.attrValues workerGroups);
    in
      lib.flatten groupedConfigs;
in

{
  fileSystems."${workingDir}" =
    { device = sourceDir;
      options = [ "bind" ];
    };

  systemd.services.create-prometheus-data-mount = {
    after = [ "data.mount" ];
    wants = [ "data.mount" ];
    before = [ "var-lib-${stateDir}.mount" ];
    wantedBy = [ "var-lib-${stateDir}.mount" ];
    serviceConfig.Type = "oneshot";
    script = ''
      mkdir -p "${workingDir}"
      mkdir -p "${sourceDir}"
      chown prometheus:prometheus "${sourceDir}"
    '';
  };

  services.prometheus = {
    enable = true;
    inherit stateDir;

    scrapeConfigs = [
      { job_name = "synapse";
        scrape_interval = "15s";
        metrics_path = "/_synapse/metrics";
        static_configs = [ (mkScrapeConfig 1 { metricsPort = mainMetricsPort; workerType = "main"; }) ]
                         ++ mkScrapeConfigs workers.allWorkers;
      }
    ];

    ruleFiles = [
      (pkgs.writeText "synapse-prometheus-v2.rules" (builtins.readFile ../files/synapse-prometheus-v2.rules))
    ];

    exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9002;
      };
    };
  };
}
