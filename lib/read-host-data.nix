let
  importJSON = import ./import-json.nix;
  info = name: ((importJSON (../hosts + "/${name}/host.json")) // { hostDir = /. + ../hosts + "/${name}"; });
in
{
  inherit info;
  secrets = name: importJSON (../hosts + "/${name}/secrets.json");

  allHosts =
    let
      isHost = hostName: (builtins.pathExists (../hosts + "/${hostName}/host.json"));
      hostNames = builtins.filter isHost (builtins.attrNames (builtins.readDir ../hosts));
    in
      builtins.map info hostNames;
}
