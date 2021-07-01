{ cfg, pkgs, lib, logConfigFile, ... }:

with lib;
let
  # Copy some requirements from <nixpkgs>/modules/misc/matrix-synapse.nix
  mkResource = r: ''{names: ${builtins.toJSON r.names}, compress: ${boolToString r.compress}}'';
  mkListener = l: ''{port: ${toString l.port}, bind_address: "${l.bind_address}", type: ${l.type}, tls: ${boolToString l.tls}, x_forwarded: ${boolToString l.x_forwarded}, resources: [${concatStringsSep "," (map mkResource l.resources)}]}'';

  # This is edited to remove database config, perspectives and turn_shared_secret.
  configText = ''
${optionalString (cfg.tls_certificate_path != null) ''
tls_certificate_path: "${cfg.tls_certificate_path}"
''}
${optionalString (cfg.tls_private_key_path != null) ''
tls_private_key_path: "${cfg.tls_private_key_path}"
''}
${optionalString (cfg.tls_dh_params_path != null) ''
tls_dh_params_path: "${cfg.tls_dh_params_path}"
''}
no_tls: ${boolToString cfg.no_tls}
${optionalString (cfg.bind_port != null) ''
bind_port: ${toString cfg.bind_port}
''}
${optionalString (cfg.unsecure_port != null) ''
unsecure_port: ${toString cfg.unsecure_port}
''}
${optionalString (cfg.bind_host != null) ''
bind_host: "${cfg.bind_host}"
''}
server_name: "${cfg.server_name}"
pid_file: "/run/matrix-synapse.pid"
${optionalString (cfg.public_baseurl != null) ''
public_baseurl: "${cfg.public_baseurl}"
''}
listeners: [${concatStringsSep "," (map mkListener cfg.listeners)}]
# databases: configured separately
event_cache_size: "${cfg.event_cache_size}"
verbose: ${cfg.verbose}
log_config: "${logConfigFile}"
rc_messages_per_second: ${cfg.rc_messages_per_second}
rc_message_burst_count: ${cfg.rc_message_burst_count}
federation_rc_window_size: ${cfg.federation_rc_window_size}
federation_rc_sleep_limit: ${cfg.federation_rc_sleep_limit}
federation_rc_sleep_delay: ${cfg.federation_rc_sleep_delay}
federation_rc_reject_limit: ${cfg.federation_rc_reject_limit}
federation_rc_concurrent: ${cfg.federation_rc_concurrent}
media_store_path: "${cfg.dataDir}/media"
uploads_path: "${cfg.dataDir}/uploads"
max_upload_size: "${cfg.max_upload_size}"
max_image_pixels: "${cfg.max_image_pixels}"
dynamic_thumbnails: ${boolToString cfg.dynamic_thumbnails}
url_preview_enabled: ${boolToString cfg.url_preview_enabled}
${optionalString (cfg.url_preview_enabled == true) ''
url_preview_ip_range_blacklist: ${builtins.toJSON cfg.url_preview_ip_range_blacklist}
url_preview_ip_range_whitelist: ${builtins.toJSON cfg.url_preview_ip_range_whitelist}
url_preview_url_blacklist: ${builtins.toJSON cfg.url_preview_url_blacklist}
''}
recaptcha_private_key: "${cfg.recaptcha_private_key}"
recaptcha_public_key: "${cfg.recaptcha_public_key}"
enable_registration_captcha: ${boolToString cfg.enable_registration_captcha}
turn_uris: ${builtins.toJSON cfg.turn_uris}
# turn_shared_secret: "${cfg.turn_shared_secret}"
enable_registration: ${boolToString cfg.enable_registration}
${optionalString (cfg.registration_shared_secret != null) ''
registration_shared_secret: "${cfg.registration_shared_secret}"
''}
recaptcha_siteverify_api: "https://www.google.com/recaptcha/api/siteverify"
turn_user_lifetime: "${cfg.turn_user_lifetime}"
user_creation_max_duration: ${cfg.user_creation_max_duration}
bcrypt_rounds: ${cfg.bcrypt_rounds}
allow_guest_access: ${boolToString cfg.allow_guest_access}

account_threepid_delegates:
  ${optionalString (cfg.account_threepid_delegates.email != null) "email: ${cfg.account_threepid_delegates.email}"}
  ${optionalString (cfg.account_threepid_delegates.msisdn != null) "msisdn: ${cfg.account_threepid_delegates.msisdn}"}

${optionalString (cfg.macaroon_secret_key != null) ''
  macaroon_secret_key: "${cfg.macaroon_secret_key}"
''}
expire_access_token: ${boolToString cfg.expire_access_token}
enable_metrics: ${boolToString cfg.enable_metrics}
report_stats: ${boolToString cfg.report_stats}
signing_key_path: "${cfg.dataDir}/homeserver.signing.key"
key_refresh_interval: "${cfg.key_refresh_interval}"
# perspectives:
redaction_retention_period: ${toString cfg.redaction_retention_period}
app_service_config_files: ${builtins.toJSON cfg.app_service_config_files}

${cfg.extraConfig}
'';
in
pkgs.writeText "homeserver.yaml" configText
