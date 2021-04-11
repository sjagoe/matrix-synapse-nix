let
  importJSON = import ./import-json.nix;
  secrets = importJSON ../secrets.json;
in
secrets
