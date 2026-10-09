#!/usr/bin/env bash
# Runs every scripts/test-*.sh and reports which ones failed.
set -uo pipefail
cd "$(dirname "$0")/.."
failed=()
for t in scripts/test-*.sh; do
    [ "$t" = "scripts/test-all.sh" ] && continue
    echo "── $t"
    bash "$t" > /dev/null 2>&1 || { bash "$t" 2>&1 | tail -20; failed+=("$t"); }
done
if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED: ${failed[*]}"
    exit 1
fi
echo "All test scripts passed."
