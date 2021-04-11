{ name, config, pkgs, ... }:
let
  readHostData = import ../lib/read-host-data.nix;
  secrets = import ../lib/global-secrets.nix;
  host = readHostData.info name;

  wireguardIp = host.ipv4.wireguard.address;

  redisPort = 6379;
  redisHome = "/data/redis";
in
{
  deployment.keys.redis-require-pass = {
    text = secrets.redis.requirePass;
    user = "redis";
  };
  users.groups.keys.members = [ "redis" ];

  services.redis = {
    enable = true;
    bind = wireguardIp;
    port = redisPort;
    requirePassFile = "/run/keys/redis-require-pass";
    extraConfig = ''
      dir ${redisHome}
    '';
  };

  # Redis tried to start before the listening address was available
  systemd.services.redis.after = [ "openssh.service" "wireguard-wg0.service" "redis-require-pass-key.service" ];
  systemd.services.redis.wants = [ "wireguard-wg0.service" "redis-require-pass-key.service" ];

  networking.firewall.interfaces.wg0.allowedTCPPorts = [ redisPort ];
  users.users.redis.createHome = true;
  users.users.redis.home = pkgs.lib.mkForce redisHome;
}
