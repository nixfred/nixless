//! Q8_0 reference kernels in plain Zig (PRD section 9, M2). This is the
//! correctness baseline the AVX2 and AVX-512 kernels are checked against.
//! Q8_0 block, from the ggml docs: f16 scale `d`, then 32 int8 quants; the
//! value of quant i is `d * q[i]`. The file stores 34 bytes per block.
//! The dot product follows ggml's generic path: the activation row is quantized
//! to Q8_0 as well, each block pair gives an exact int32 sum, and the float
//! part is `acc += isum * (d_w * d_x)` in f32, block order, no fused multiply-add.
const std = @import("std");
const cpuinfo = @import("cpuinfo.zig");

pub const BLOCK = 32;
pub const BLOCK_BYTES = 34;

/// An activation block as the kernels use it (not a file format).
pub const ActBlock = extern struct { d: f32, q: [BLOCK]i8 };

pub fn f16ToF32(bits: u16) f32 {
    const h: f16 = @bitCast(bits);
    return @floatCast(h);
}

pub fn f32ToF16Bits(x: f32) u16 {
    const h: f16 = @floatCast(x);
    return @bitCast(h);
}

/// Round half away from zero, like C `roundf`. `|v|` stays under 128 here.
fn roundAway(v: f32) i32 {
    const t: i32 = @intFromFloat(v); // truncates toward zero
    const frac = v - @as(f32, @floatFromInt(t));
    if (frac >= 0.5) return t + 1;
    if (frac <= -0.5) return t - 1;
    return t;
}

/// ggml's `quantize_row_q8_0`: d = amax/127, q = round(x/d).
/// The scale is stored as f16 in the file format, so it is rounded the same way here.
pub fn quantizeRow(x: []const f32, out: []ActBlock) void {
    std.debug.assert(x.len == out.len * BLOCK);
    for (out, 0..) |*b, i| {
        const src = x[i * BLOCK ..][0..BLOCK];
        var amax: f32 = 0;
        for (src) |v| {
            const a = if (v < 0) -v else v;
            if (a > amax) amax = a;
        }
        const d = amax / 127.0;
        const id: f32 = if (d != 0) 1.0 / d else 0;
        b.d = f16ToF32(f32ToF16Bits(d));
        for (src, 0..) |v, j| b.q[j] = @intCast(roundAway(v * id));
    }
}

fn rdF16(p: []const u8) f32 {
    return f16ToF32(std.mem.readInt(u16, p[0..2], .little));
}

/// y[r] = dot(row r of W, x) for `rows` rows of `cols` columns. `w` is the raw
/// Q8_0 tensor bytes (row-major, `cols/32` blocks per row), `x` the quantized
/// activation. Returns the sum of every block's integer dot, an exact checksum.
pub fn matvecQ8(w: []const u8, rows: usize, cols: usize, x: []const ActBlock, y: []f32) i64 {
    const nb = cols / BLOCK;
    std.debug.assert(w.len == rows * nb * BLOCK_BYTES and x.len == nb and y.len >= rows);
    var checksum: i64 = 0;
    for (0..rows) |r| {
        var acc: f32 = 0;
        for (0..nb) |b| {
            const blk = w[(r * nb + b) * BLOCK_BYTES ..][0..BLOCK_BYTES];
            var isum: i32 = 0;
            for (0..BLOCK) |i| {
                const wq: i8 = @bitCast(blk[2 + i]);
                isum += @as(i32, wq) * @as(i32, x[b].q[i]);
            }
            checksum += isum;
            acc += @as(f32, @floatFromInt(isum)) * (rdF16(blk[0..2]) * x[b].d);
        }
        y[r] = acc;
    }
    return checksum;
}

extern fn q8_row_dot_avx2(w: [*]const u8, x: [*]const ActBlock, nb: usize, isum: *i64) u32;

/// The AVX2 kernel needs AVX2 and F16C state enabled on this CPU.
pub fn haveAvx2() bool {
    return cpuinfo.features.avx2 and cpuinfo.features.f16c and cpuinfo.xcr0 & 0x4 != 0;
}

/// Same contract and same bits as `matvecQ8`, using the AVX2 kernel.
pub fn matvecQ8Avx2(w: []const u8, rows: usize, cols: usize, x: []const ActBlock, y: []f32) i64 {
    const nb = cols / BLOCK;
    std.debug.assert(w.len == rows * nb * BLOCK_BYTES and x.len == nb and y.len >= rows);
    var checksum: i64 = 0;
    for (0..rows) |r| y[r] = @bitCast(q8_row_dot_avx2(w[r * nb * BLOCK_BYTES ..].ptr, x.ptr, nb, &checksum));
    return checksum;
}
