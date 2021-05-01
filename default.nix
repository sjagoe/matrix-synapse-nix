{ pkgs ? import <nixpkgs> {}, ... }:

{
  create =
    pkgs.mkShell {
      buildInputs = with pkgs; [
        hcloud
        python3Full
        python3Packages.netaddr
        python3Packages.click
        python3Packages.fasteners
        python3Packages.attrs
        python3Packages.requests
        wireguard
      ];
    };
  nixops =
    pkgs.mkShell {
      shellHook = ''
        echo "You should edit this to set up nixops v2.0 in this shell..."
        export NIX_PATH="nixpkgs=$(pwd)/pkgs/nixpkgs"
      '';
    };
}
