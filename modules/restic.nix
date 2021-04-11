{ name, config, pkgs, lib, ... }:
let
  readHostData = import ../lib/read-host-data.nix;
  secrets = import ../lib/global-secrets.nix;

  network = (import ../lib/network-info.nix);
  host = readHostData.info name;
  hostSecrets = readHostData.secrets name;

  unitName = "vectornet-restic";
  user = "restic";

  options = [
    "--exclude-caches"
    "--one-file-system"
    "--limit-upload=10240" # 10 MiB/s (80Mbits/s) in KiB/s
  ];
  backupOptions = lib.concatStringsSep " " options;
  backupPaths = lib.concatStringsSep " " host.restic.paths;
in
{
  deployment.keys.restic-credentials = {
    text = ''
      AWS_ACCESS_KEY_ID=${secrets.restic.awsAccessKeyId}
      AWS_SECRET_ACCESS_KEY=${secrets.restic.awsSecretAccessKey}
    '';
    inherit user;
  };
  deployment.keys.restic-backup-enc = {
    text = hostSecrets.restic;
    inherit user;
  };
  users.groups.keys.members = [ user ];

  environment.systemPackages = [ pkgs.restic ];
  systemd.timers."${unitName}" = {
    timerConfig = host.restic.timerConfig;
    wantedBy = [ "timers.target" ];
  };
  systemd.services."${unitName}" =
    let
      pruneOpts = (lib.concatStringsSep " " network.restic.pruneOpts);
    in
    {
    serviceConfig = {
      Type = "oneshot";
      User = user;
      Group = user;
      AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
      CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
      EnvironmentFile = "/run/keys/restic-credentials";
      RuntimeDirectory = "restic-backups-${name}";
      ExecStart = [
        "${pkgs.restic}/bin/restic backup ${backupOptions} ${backupPaths}"
        "${pkgs.restic}/bin/restic forget --prune ${pruneOpts}"
        "${pkgs.restic}/bin/restic check"
        "${pkgs.restic}/bin/restic snapshots"
      ];
    };
    wants = [ "${unitName}.timer" ];
    description = "Restic backups to Amazon S3";

    environment = {
      RESTIC_PASSWORD_FILE = "/run/keys/restic-backup-enc";
      RESTIC_REPOSITORY = "${secrets.restic.root}/${name}";
      RCLONE_BWLIMIT = "10M";
    };

    preStart = "${pkgs.restic}/bin/restic snapshots || ${pkgs.restic}/bin/restic init";
  };
  users.users.${user} = {
    name = user;
    group = user;
    uid = config.ids.uids.${user};
    home = "/var/restic";
    createHome = true;
  };
  users.groups.${user}.gid = config.ids.gids.${user};
}
