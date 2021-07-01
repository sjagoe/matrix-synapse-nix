{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "synapse-find-unreferenced-state-groups";
  version = "82817e4357";

  src = fetchFromGitHub {
    owner = "erikjohnston";
    repo = pname;
    rev = "82817e4357fb44dda2d76087157c9b8a96781882";
    sha256 = "0jv3idncg9jxc0s73yylkiv4shdqj137h1lspa5yv6hwn4cqzhjn";
  };

  cargoSha256 = "1vs5syahpz7q4ywcwd6q9qjmy0wmhf7asfdksyzqgz3gdc45jng6";

  meta = with lib; {
    description = "A tool to find unreferenced state groups in the synapse database";
    homepage = "https://github.com/erikjohnston/synapse-find-unreferenced-state-groups";
    license = licenses.mit;
    maintainers = with maintainers; [ sjagoe ];
  };
}
