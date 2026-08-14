#!/bin/bash
set -u
SCRIPT_DIR="$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)" || exit 1
exec /bin/bash "$SCRIPT_DIR/bin/dsh-service" install
