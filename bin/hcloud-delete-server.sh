#!/usr/bin/env bash

set -eu
set -o pipefail

DIR="$(dirname "$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )")"

# shellcheck source=../lib/lib.sh
source "$DIR/lib/lib.sh"

destroyserver "$@"
