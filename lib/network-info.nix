let
  importJSON = import ./import-json.nix;
  networkInfo = importJSON ../network.json;
in
networkInfo
