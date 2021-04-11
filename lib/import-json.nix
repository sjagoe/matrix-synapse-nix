let
  importJSON = path: builtins.fromJSON (builtins.readFile path);
in
importJSON
