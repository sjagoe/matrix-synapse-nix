{ name, config, pkgs, ...}:
let
  networkInfo = import ../lib/network-info.nix;

  inputs = import ../lib/telegraf-inputs.nix;
in
{
  services.telegraf = {
    enable = true;
    extraConfig = {
      outputs.socket_writer = [
        {
          address = "tcp://${networkInfo.metrics.metricsHost}:${toString networkInfo.metrics.metricsPort}";
          data_format = "influx";
        }
      ];
      inherit inputs;
    };
  };
}
