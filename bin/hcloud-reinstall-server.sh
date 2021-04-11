#!/usr/bin/env bash

set -eu
set -o pipefail

DIR="$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")"

# shellcheck source=../lib/lib.sh
source "$DIR/lib/lib.sh"

servername="$1"
sshkeyname="$2"
regenkeys=
set +u
if [[ "$3" == "true" ]]; then
   regenkeys=true
fi
set -u
reinstallserver "$servername" "$sshkeyname" "$regenkeys"
