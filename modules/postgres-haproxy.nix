{ name, config, nodes, pkgs, ... }:

let
  dbHosts =
    let
      dbNodeNamePattern = "^vecnetdb[[:digit:]]+\.${config.networking.domain}$";
    in
    builtins.filter
      (nodeName: (builtins.match dbNodeNamePattern nodeName) != null)
      (builtins.attrNames nodes);
  backendServers = pkgs.lib.concatStringsSep "\n"
    (map (host: "  server ${host} ${host}:5432 maxconn 2000 check") dbHosts);
in
{
  services.haproxy = {
    enable = true;
    config = ''
      global
        maxconn 10000
        log /dev/log local0 info alert
        # chroot /var/lib/haproxy
        stats socket /run/haproxy/admin.sock mode 660 level admin
        stats timeout 30s
        user haproxy
        group haproxy
        daemon
        tune.maxrewrite 16384
        tune.bufsize 32768

        # Default SSL material locations
        ca-base /etc/ssl/certs
        crt-base /etc/ssl/private

        # Default ciphers to use on SSL-enabled listening sockets.
        # For more information, see ciphers(1SSL). This list is from:
        #  https://hynek.me/articles/hardening-your-web-servers-ssl-ciphers/
        ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:ECDH+3DES:DH+3DES:RSA+AESGCM:RSA+AES:RSA+3DES:!aNULL:!MD5:!DSS
        ssl-default-bind-options no-sslv3

      defaults
        log global
        mode tcp
        option tcplog
        option dontlognull
        timeout connect 5s
        timeout client 0
        timeout server 0

      frontend pg_frontend
        mode tcp
        bind 127.0.0.1:5432
        use_backend pg_backend
      frontend stats
        mode http
        bind 127.0.0.1:89
        stats uri /

      backend pg_backend
        balance roundrobin
        option tcp-check
        tcp-check expect string OK\ (node\ is\ primary)
        default-server port 9999 inter 5s downinter 5s rise 1 fall 3 slowstart 60s on-marked-down shutdown-sessions
      ${backendServers}
    '';
  };
}
