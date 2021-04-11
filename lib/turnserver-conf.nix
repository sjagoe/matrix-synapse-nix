{ cfg, lib, staticAuthSecret, ... }:
let
  concatStringsSep = builtins.concatStringsSep;
  # Copied from
  # https://github.com/NixOS/nixpkgs/blob/nixos-20.09/nixos/modules/services/networking/coturn.nix
  # To allow putting the config with static-auth-secret into a private
  # location rather than world-readable in the nix store
  pidfile = "/run/turnserver/turnserver.pid";
  configText = ''
    listening-port=${toString cfg.listening-port}
    tls-listening-port=${toString cfg.tls-listening-port}
    alt-listening-port=${toString cfg.alt-listening-port}
    alt-tls-listening-port=${toString cfg.alt-tls-listening-port}
    ${concatStringsSep "\n" (map (x: "listening-ip=${x}") cfg.listening-ips)}
    ${concatStringsSep "\n" (map (x: "relay-ip=${x}") cfg.relay-ips)}
    min-port=${toString cfg.min-port}
    max-port=${toString cfg.max-port}
    ${lib.optionalString cfg.lt-cred-mech "lt-cred-mech"}
    ${lib.optionalString cfg.no-auth "no-auth"}
    ${lib.optionalString cfg.use-auth-secret "use-auth-secret"}
    static-auth-secret=${staticAuthSecret}
    realm=${cfg.realm}
    ${lib.optionalString cfg.no-udp "no-udp"}
    ${lib.optionalString cfg.no-tcp "no-tcp"}
    ${lib.optionalString cfg.no-tls "no-tls"}
    ${lib.optionalString cfg.no-dtls "no-dtls"}
    ${lib.optionalString cfg.no-udp-relay "no-udp-relay"}
    ${lib.optionalString cfg.no-tcp-relay "no-tcp-relay"}
    ${lib.optionalString (cfg.cert != null) "cert=${cfg.cert}"}
    ${lib.optionalString (cfg.pkey != null) "pkey=${cfg.pkey}"}
    ${lib.optionalString (cfg.dh-file != null) ("dh-file=${cfg.dh-file}")}
    no-stdout-log
    syslog
    pidfile=${pidfile}
    ${lib.optionalString cfg.secure-stun "secure-stun"}
    ${lib.optionalString cfg.no-cli "no-cli"}
    cli-ip=${cfg.cli-ip}
    cli-port=${toString cfg.cli-port}
    ${lib.optionalString (cfg.cli-password != null) ("cli-password=${cfg.cli-password}")}
    ${cfg.extraConfig}
  '';
in
configText
