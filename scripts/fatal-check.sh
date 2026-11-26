#!/usr/bin/env bash
# Boot-fatal tests (PRD 14.7): bad model input must stop the kernel with a stable
# FATAL code and no fault. One ISO per case, booted under SeaBIOS.
# Usage: scripts/fatal-check.sh [none bad-magic truncated bad-type bad-arch qwen3-no-hparams qwen3-bad-shape qwen3-missing]   (default: all)
set -u -o pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || set -- none bad-magic truncated bad-type bad-arch qwen3-no-hparams qwen3-bad-shape qwen3-missing
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
for kind in "$@"; do
    case $kind in
    none)      pat='FATAL E_NO_MODEL'; model=none ;;
    bad-magic) pat='FATAL E_GGUF_BAD: not a GGUF'; model=tests/fixtures/bad-magic.gguf ;;
    truncated) pat='FATAL E_GGUF_BAD: file is truncated'; model=tests/fixtures/truncated.gguf ;;
    bad-type)  pat='FATAL E_GGUF_TYPE: tensor blk.0.q4k has type Q4_K'; model=tests/fixtures/bad-type.gguf ;;
    bad-arch)        pat='FATAL E_ARCH_UNSUPPORTED: llama: only qwen3'; model=tests/fixtures/bad-arch.gguf ;;
    qwen3-no-hparams)   pat='FATAL E_MODEL_KEY: qwen3.block_count'; model=tests/fixtures/qwen3-no-hparams.gguf ;;
    qwen3-bad-shape) pat='FATAL E_MODEL_SHAPE: blk.1.attn_q.weight'; model=tests/fixtures/qwen3-bad-shape.gguf ;;
    qwen3-missing)   pat='FATAL E_MODEL_MISSING: blk.1.ffn_down.weight'; model=tests/fixtures/qwen3-missing.gguf ;;
    *) echo "unknown kind: $kind"; exit 2 ;;
    esac
    zig build iso -Dmodel="$model" -p "$tmp/$kind" >/dev/null 2>&1 || { echo "FAIL $kind: build"; fail=1; continue; }
    ISO="$tmp/$kind/nixless.iso" LOG_TAG="fatal-$kind" EXPECT="nixless: $pat" \
        CHECKPOINTS= ALLOW_PANIC=1 ALIVE_AFTER=1 BOOT_TIMEOUT=${BOOT_TIMEOUT:-60} \
        scripts/qemu-boot-check.sh seabios | sed "s/^PASS seabios/PASS $kind/; s/^FAIL seabios/FAIL $kind/" || fail=1
done
exit $fail
