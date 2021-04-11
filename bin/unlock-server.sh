#!/usr/bin/env bash

set -eu
set -o pipefail

DIR="$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")"

# shellcheck source=../lib/lib.sh
source "$DIR/lib/lib.sh"

unlock "$1" "load" "$HOME/.ssh/identities/personal/id_ed25519-2021-04-17"
