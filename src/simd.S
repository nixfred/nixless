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

# u32 q8_row_dot_avx2(const u8 *w /*rdi*/, const ActBlock *x /*rsi*/, usize nb /*rdx*/, i64 *isum /*rcx*/)
# One row of a Q8_0 matrix-vector product (PRD section 11). w is nb file blocks
# (34 bytes: f16 scale, 32 int8); x is nb activation blocks (36 bytes: f32 scale,
# 32 int8). Per block: exact int32 dot via |w| * sign(x, w) (vpmaddubsw then
# vpmaddwd), then acc += f32(isum) * (d_w * d_x) in scalar float, the same
# operations in the same order as the Zig reference, so the result is bit-identical.
# Weights may hold -128 (read as +128 after the abs, still correct); activation
# quants come from our quantizer and stay within -127..127, so vpmaddubsw cannot
# saturate. The kernel target is soft-float, so floats cross the call as bits:
# returns the row sum's IEEE bits in eax and adds the integer sums to *isum.
.global q8_row_dot_avx2
q8_row_dot_avx2:
    vxorps     xmm0, xmm0, xmm0
    vpcmpeqw   ymm7, ymm7, ymm7
    vpsrlw     ymm7, ymm7, 15            # 16 x int16 ones
    xor        r8, r8
1:  test       rdx, rdx
    jz         9f
    vmovdqu    ymm1, [rdi + 2]           # w quants
    vmovdqu    ymm2, [rsi + 4]           # x quants
    vpsignb    ymm3, ymm1, ymm1          # |w|
    vpsignb    ymm4, ymm2, ymm1          # x with the sign of w
    vpmaddubsw ymm5, ymm3, ymm4          # pairs -> 16 x int16
    vpmaddwd   ymm5, ymm5, ymm7          # pairs -> 8 x int32
    vextracti128 xmm6, ymm5, 1
    vpaddd     xmm5, xmm5, xmm6
    vpshufd    xmm6, xmm5, 0x4E
    vpaddd     xmm5, xmm5, xmm6
    vpshufd    xmm6, xmm5, 0xB1
    vpaddd     xmm5, xmm5, xmm6
    vmovd      eax, xmm5
    movsxd     r9, eax
    add        r8, r9
    vcvtsi2ss  xmm6, xmm6, eax           # f32(isum)
    movzx      eax, word ptr [rdi]
    vmovd      xmm5, eax
    vcvtph2ps  xmm5, xmm5                # d_w
    vmulss     xmm5, xmm5, dword ptr [rsi]   # d_w * d_x
    vmulss     xmm6, xmm6, xmm5          # isum * (d_w * d_x)
    vaddss     xmm0, xmm0, xmm6
    add        rdi, 34
    add        rsi, 36
    dec        rdx
    jmp        1b
9:  add        [rcx], r8
    vmovd      eax, xmm0
    vzeroupper
    ret
