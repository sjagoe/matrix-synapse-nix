#!/usr/bin/env bash

set -eu
set -o pipefail

DIR="$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")"

# shellcheck source=../lib/lib.sh
source "$DIR/lib/lib.sh"

newserverid="$(createserver "$@")"
servername="$1"
sshkeyname="$5"
installserver "$servername" "$newserverid" "$sshkeyname"
