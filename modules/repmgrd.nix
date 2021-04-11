{ name, config, ... }:
let
  readHostData = import ../lib/read-host-data.nix;
  inherit (readHostData) allHosts;
  host = readHostData.info name;
  repmgrPubKeyFiles = builtins.filter builtins.pathExists
    (builtins.map (host: (host.hostDir + /keys/repmgr_ed25519_key.pub)) allHosts);
  repmgrPubKeys = builtins.map builtins.readFile repmgrPubKeyFiles;
in
{
  deployment.keys.id_ed25519 = {
    keyFile = host.hostDir + /keys/repmgr_ed25519_key;
    user = "postgres";
    group = "postgres";
    destDir = "/data/postgresql/.ssh";
  };
  deployment.keys.known_hosts = {
    keyFile = ../ssh/ssh_known_hosts;
    user = "postgres";
    group = "postgres";
    destDir = "/data/postgresql/.ssh";
  };
  users.groups.keys.members = [ "postgres" ];
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 22 ];
  # repmgr_ed25519_key.pub
  systemd.services.repmgrd = {
    after = [ "openssh.service" "postgresql.service" "repmgr-passwd-key.service" ];
    wants = [ "postgresql.service" "repmgr-passwd-key.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.postgresql.package.pkgs.repmgr ];
    serviceConfig = {
      PIDFile = "/run/postgresql/repmgrd.pid";
      Type = "forking";
      User = "postgres";
      Group = "postgres";
    };
    script = ''
      repmgrd -f /etc/repmgr.conf --pid-file /run/postgresql/repmgrd.pid
    '';
  };
  users.users.postgres.openssh.authorizedKeys.keys = repmgrPubKeys;
}
