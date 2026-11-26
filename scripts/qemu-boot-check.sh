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
banner=${EXPECT:-'nixless [0-9][0-9.]* [0-9a-zA-Z.-]* booting'}
# EXPECT overrides the pattern; ALLOW_PANIC=1 lets PANIC/FATAL through (panic tests);
# ALIVE_AFTER=1 also requires QEMU still running a second later (halted, not reset).

# CHECKPOINTS: extra lines that must also appear (one per line), added per milestone.
checkpoints=${CHECKPOINTS-$'mem: usable\npmm: \nvmm: direct map ok'}

[ -r "$iso" ] || { echo "no ISO at $iso (run: zig build iso)"; exit 2; }
mkdir -p "$out"
[ $# -gt 0 ] || set -- seabios ovmf

fail=0
for fw in "$@"; do
    tag=${LOG_TAG:-$fw}
    log="$out/$tag.log"
    : >"$log"
    args=(-machine q35 -smp 1 -m ${MEM:-256} -cdrom "$iso" -boot d
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

    nice -n 10 qemu-system-x86_64 "${args[@]}" >"$out/$tag.qemu.err" 2>&1 &
    qpid=$!
    seen=0
    for _ in $(seq 1 $((timeout_s * 5))); do
        if grep -qE "$banner" "$log"; then
            seen=1
            while IFS= read -r cp; do
                [ -z "$cp" ] || grep -qF "$cp" "$log" || seen=0
            done <<<"$checkpoints"
            [ $seen = 1 ] && break
        fi
        kill -0 "$qpid" 2>/dev/null || break
        sleep 0.2
    done
    alive=1
    if [ "${ALIVE_AFTER:-0}" = 1 ] && [ $seen = 1 ]; then
        sleep 1
        kill -0 "$qpid" 2>/dev/null || alive=0
    fi
    kill "$qpid" 2>/dev/null
    wait "$qpid" 2>/dev/null
    [ "${vars:-}" ] && rm -f "$vars" && vars=

    if [ $seen = 1 ] && [ $alive = 1 ] && { [ "${ALLOW_PANIC:-0}" = 1 ] || ! grep -qE 'PANIC|FATAL' "$log"; }; then
        echo "PASS $fw: $(grep -E "$banner" "$log" | head -1 | tr -d '\r') ${checkpoints:+(+ checkpoints)}"
    else
        echo "FAIL $fw (log: $log)"; sed 's/^/    qemu: /' "$out/$tag.qemu.err" | head -5; sed 's/^/    /' "$log" | head -20
        fail=1
    fi
done
exit $fail
