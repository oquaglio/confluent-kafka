#!/usr/bin/env bash
# produce.sh <a|b> [n]: send n records with the next seq numbers to a cluster's `orders` topic.
. "$(dirname "$0")/lib.sh"
produce "${1:?cluster a or b}" "${2:-100}"
