# SIMD self-tests: execute one AVX2 and one AVX-512 instruction sequence so a
# CPU whose XCR0/CR4 state is not enabled faults (#UD) right away instead of
# in the middle of inference. Built as its own object with AVX features on
# (see build.zig); the rest of the kernel stays SSE-free.
.intel_syntax noprefix
.section .text

.global simd_selftest_avx2
simd_selftest_avx2:
    vpcmpeqd ymm0, ymm0, ymm0
    vpxor    ymm1, ymm1, ymm1
    vpaddd   ymm2, ymm0, ymm1
    vzeroupper
    ret

.global simd_selftest_avx512
simd_selftest_avx512:
    vpxord     zmm0, zmm0, zmm0
    vpternlogd zmm1, zmm1, zmm1, 0xFF
    kxnorw     k1, k1, k1
    vpaddd     zmm2 {k1}, zmm1, zmm0
    vzeroupper
    ret
