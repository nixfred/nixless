#!/usr/bin/env bash
# Local boot check: boot zig-out/nixless.iso under QEMU q35 + KVM with SeaBIOS
# and with OVMF, capture COM1, and assert the banner (PRD sections 0 and 14.1).
# Usage: scripts/qemu-boot-check.sh [seabios|ovmf ...]   (default: both)
# Exit 0 only if every requested firmware printed the banner and no PANIC/FATAL.
set -u
cd "$(dirname "$0")/.."

iso=${ISO:-zig-out/nixless.iso}
timeout_s=${BOOT_TIMEOUT:-20}
out=${BOOT_LOG_DIR:-bootlogs}
ovmf_code=${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}
ovmf_vars=${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}
banner='nixless [0-9][0-9.]* [0-9a-zA-Z.-]* booting'

[ -r "$iso" ] || { echo "no ISO at $iso (run: zig build iso)"; exit 2; }
mkdir -p "$out"
[ $# -gt 0 ] || set -- seabios ovmf

fail=0
for fw in "$@"; do
    log="$out/$fw.log"
    : >"$log"
    args=(-machine q35 -smp 1 -m 256 -cdrom "$iso" -boot d
          -display none -no-reboot -serial "file:$log")
    # KVM when this user may use it, else TCG (slow, fine for M0).
    if [ -w /dev/kvm ]; then args+=(-enable-kvm -cpu host); else args+=(-cpu max); fi
    case $fw in
    seabios) ;;
    ovmf)
        vars=$(mktemp)
        cp "$ovmf_vars" "$vars"
        args+=(-drive "if=pflash,format=raw,readonly=on,file=$ovmf_code"
               -drive "if=pflash,format=raw,file=$vars")
        ;;
    *) echo "unknown firmware: $fw"; exit 2 ;;
    esac

    nice -n 10 qemu-system-x86_64 "${args[@]}" >"$out/$fw.qemu.err" 2>&1 &
    qpid=$!
    seen=0
    for _ in $(seq 1 $((timeout_s * 5))); do
        if grep -qE "$banner" "$log"; then seen=1; break; fi
        kill -0 "$qpid" 2>/dev/null || break
        sleep 0.2
    done
    kill "$qpid" 2>/dev/null
    wait "$qpid" 2>/dev/null
    [ "${vars:-}" ] && rm -f "$vars" && vars=

    if [ $seen = 1 ] && ! grep -qE 'PANIC|FATAL' "$log"; then
        echo "PASS $fw: $(grep -E "$banner" "$log" | tr -d '\r')"
    else
        echo "FAIL $fw (log: $log)"; sed 's/^/    qemu: /' "$out/$fw.qemu.err" | head -5; sed 's/^/    /' "$log" | head -20
        fail=1
    fi
done
exit $fail
