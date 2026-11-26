#!/usr/bin/env bash
# Panic tests (PRD 14.7): build one ISO per deliberate fault, boot it under
# SeaBIOS, and require the expected PANIC line on serial with QEMU still
# running afterwards (halted, not reset by a triple fault).
# Usage: scripts/panic-check.sh [pf de ud df assert ...]   (default: all)
set -u -o pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- pf de ud df assert
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
for kind in "$@"; do
    case $kind in
    pf)     pat='#PF page fault' ;;
    de)     pat='#DE divide error' ;;
    ud)     pat='#UD invalid opcode' ;;
    df)     pat='#DF double fault' ;;
    assert) pat='assertion test' ;;
    *) echo "unknown kind: $kind"; exit 2 ;;
    esac
    zig build iso -Dpanic-test="$kind" -p "$tmp/$kind" >/dev/null 2>&1 || { echo "FAIL $kind: build"; fail=1; continue; }
    ISO="$tmp/$kind/nixless.iso" LOG_TAG="panic-$kind" EXPECT="nixless PANIC: $pat" \
        ALLOW_PANIC=1 ALIVE_AFTER=1 BOOT_TIMEOUT=${BOOT_TIMEOUT:-60} \
        scripts/qemu-boot-check.sh seabios | sed "s/^PASS seabios/PASS $kind/; s/^FAIL seabios/FAIL $kind/" || fail=1
done
exit $fail
