let
  splitHostName = name: (builtins.match "([[:alnum:]]+)\.(.*)" name);
  stringToInt = import ./string-to-int.nix;
in
{
  # Take the first component of the fqdn
  nameToHostname = name: (builtins.elemAt (splitHostName name) 0);
  nameToDomain = name: (builtins.elemAt (splitHostName name) 1);

  hostNumber = name: (stringToInt (builtins.head (builtins.match "[[:alpha:]]+([[:digit:]]+)\..*" name)));
}
