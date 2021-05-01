{}:

let
  readHostData = import ./lib/read-host-data.nix;

  networkInfo = import ./lib/network-info.nix;
  networks = networkInfo.networks;
  domain = networkInfo.domain;

  secrets = import ./lib/global-secrets.nix;
  targetUser = secrets.ssh.nixopsAdmin;
  getWireguardKey = name: (readHostData.secrets name).wireguard.private;
  deploymentInfo = name: ({
    keys.wg-private.text = getWireguardKey name;
    targetHost = name;
    inherit targetUser;
    sshOptions = [
      "-o" "StrictHostKeyChecking=yes"
      "-o" ("UserKnownHostsFile=" + ./ssh/ssh_known_hosts)
    ];
    provisionSSHKey = false;
  });
in
{
  network.description = "Matrix-Synapse for ${domain}";

  "db1.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/postgres.nix
        ./modules/restic.nix
      ] ++ (if networkInfo.postgres.repmgrdEnabled then [ ./modules/repmgrd.nix ] else []);
      deployment = deploymentInfo name;
    };

  "db2.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/postgres.nix
        ./modules/restic.nix
      ] ++ (if networkInfo.postgres.repmgrdEnabled then [ ./modules/repmgrd.nix ] else []);
      deployment = deploymentInfo name;
    };

  "app1.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/matrix-synapse.nix
        ./modules/restic.nix
      ];
      deployment = deploymentInfo name;
    };

  "turn1.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/telegraf.nix
        ./modules/coturn.nix
      ];
      networking.firewall.allowPing = false;
      deployment = deploymentInfo name;
    };

  "redis1.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/telegraf.nix
        ./modules/redis.nix
        ./modules/restic.nix
      ];
      deployment = deploymentInfo name;
    };

  "metrics1.${domain}" =
    { name, config, pkgs, ... }:
    {
      imports = [
        ./modules/machine-config.nix
        ./modules/metrics.nix
      ];
      deployment = deploymentInfo name;
    };
}
