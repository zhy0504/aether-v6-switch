#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n v6.sh
bash v6.sh --help >/tmp/aether-v6-switch-help.out
grep -q -- '--native-via' /tmp/aether-v6-switch-help.out
grep -q 'qh repair' v6.sh
grep -q 'probe_http_only' v6.sh
grep -q 'ROUTE_FIX_FILE' v6.sh
grep -q 'mtu' v6.sh
echo "tests ok"
